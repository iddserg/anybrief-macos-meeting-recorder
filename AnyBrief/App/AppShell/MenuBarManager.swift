import AppKit

struct MenuBarContext {
    let appState: AppState
    let currentSession: RecordingSession?
}

final class MenuBarManager {
    private var statusItem: NSStatusItem?

    func install(context: MenuBarContext, target: AnyObject) {
        if let statusItem {
            NSStatusBar.system.removeStatusItem(statusItem)
        }
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem = item
        update(context: context, target: target)
    }

    func update(context: MenuBarContext, target: AnyObject) {
        statusItem?.button?.image = image(for: context.appState)
        statusItem?.button?.title = statusText(for: context)
        statusItem?.button?.imagePosition = context.currentSession == nil ? .imageOnly : .imageLeading
        statusItem?.length = context.currentSession == nil ? NSStatusItem.squareLength : NSStatusItem.variableLength
        statusItem?.menu = makeMenu(for: context, target: target)
    }

    func makeMenu(for context: MenuBarContext, target: AnyObject) -> NSMenu {
        let menu = NSMenu()
        menu.addItem(makeItem(
            title: String(localized: "Start Recording"),
            action: #selector(AppDelegate.startRecording),
            target: target,
            systemImage: "record.circle",
            isEnabled: context.currentSession == nil && context.appState != .needsPermissions,
            identifier: "menubar.record.start"
        ))
        menu.addItem(makeItem(
            title: String(localized: "Stop Recording"),
            action: #selector(AppDelegate.stopRecording),
            target: target,
            systemImage: "stop.circle",
            isEnabled: context.appState == .recording,
            identifier: "menubar.record.stop"
        ))
        menu.addItem(makeItem(
            title: String(localized: "Force-stop Current Recording"),
            action: #selector(AppDelegate.forceStopCurrentRecording),
            target: target,
            systemImage: "xmark.circle",
            isEnabled: context.currentSession != nil,
            identifier: "menubar.record.forceStop"
        ))
        menu.addItem(makeItem(
            title: context.currentSession?.microphonePaused == true
                ? String(localized: "Disable Microphone Silence Recording")
                : String(localized: "Enable Microphone Silence Recording"),
            action: #selector(AppDelegate.toggleMicrophonePause),
            target: target,
            systemImage: context.currentSession?.microphonePaused == true ? "mic.fill" : "mic.slash",
            isEnabled: context.appState == .recording,
            identifier: "menubar.mic.toggle"
        ))
        if let currentSession = context.currentSession,
           currentSession.source == "calendar",
           !currentSession.autoStopDisabled {
            menu.addItem(makeInfoItem(title: String(
                format: String(localized: "Current Meeting: %@"),
                currentSession.title
            )))
            menu.addItem(makeItem(
                title: String(localized: "Disable Auto-Stop for Current Meeting"),
                action: #selector(AppDelegate.disableAutoStopForCurrentMeeting),
                target: target,
                systemImage: "timer",
                isEnabled: true
            ))
        }
        menu.addItem(.separator())
        menu.addItem(makeItem(
            title: String(localized: "Open Dashboard"),
            action: #selector(AppDelegate.openDashboard),
            target: target,
            systemImage: "sidebar.left",
            identifier: "menubar.openDashboard"
        ))
        menu.addItem(makeItem(
            title: String(localized: "Open Today Folder"),
            action: #selector(AppDelegate.openTodayFolder),
            target: target,
            systemImage: "folder",
            identifier: "menubar.openTodayFolder"
        ))
        menu.addItem(makeItem(
            title: String(localized: "Open Logs"),
            action: #selector(AppDelegate.openLogs),
            target: target,
            systemImage: "terminal",
            identifier: "menubar.openLogs"
        ))
        menu.addItem(makeItem(
            title: String(localized: "About AnyBrief"),
            action: #selector(AppDelegate.openAbout),
            target: target,
            systemImage: "info.circle"
        ))
        menu.addItem(.separator())
        menu.addItem(makeItem(
            title: String(localized: "Quit"),
            action: #selector(AppDelegate.quit),
            target: target,
            systemImage: "power",
            keyEquivalent: "q"
        ))
        return menu
    }

    private func image(for appState: AppState) -> NSImage? {
        appIcon(for: appState)
    }

    private func appIcon(for appState: AppState) -> NSImage {
        let size = NSSize(width: 20, height: 20)
        let image = NSImage(size: size)
        image.lockFocus()

        if let mark = NSImage(named: "SmallMenuIcon") {
            mark.draw(in: NSRect(origin: .zero, size: size))
        }

        if let indicatorColor = indicatorColor(for: appState) {
            let indicatorRect = NSRect(x: 13.2, y: 1.8, width: 5.6, height: 5.6)
            NSColor.controlBackgroundColor.setFill()
            NSBezierPath(ovalIn: indicatorRect.insetBy(dx: -1.2, dy: -1.2)).fill()
            indicatorColor.setFill()
            NSBezierPath(ovalIn: indicatorRect).fill()
        }

        image.unlockFocus()
        image.isTemplate = false
        image.accessibilityDescription = accessibilityDescription(for: appState)
        return image
    }

    private func indicatorColor(for appState: AppState) -> NSColor? {
        switch appState {
        case .idle, .needsPermissions:
            return nil
        case .recording:
            return .systemRed
        case .processing:
            return .systemOrange
        case .error:
            return .systemRed
        }
    }

    private func accessibilityDescription(for appState: AppState) -> String {
        switch appState {
        case .idle:
            return String(localized: "AnyBrief idle")
        case .needsPermissions:
            return String(localized: "AnyBrief needs permissions")
        case .recording:
            return String(localized: "AnyBrief recording")
        case .processing:
            return String(localized: "AnyBrief processing")
        case .error:
            return String(localized: "AnyBrief error")
        }
    }

    private func statusText(for context: MenuBarContext) -> String {
        guard context.appState == .recording else {
            return ""
        }

        return String(localized: "REC")
    }

    private func makeItem(
        title: String,
        action: Selector,
        target: AnyObject,
        systemImage: String? = nil,
        isEnabled: Bool = true,
        keyEquivalent: String = "",
        identifier: String? = nil
    ) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: keyEquivalent)
        item.target = target
        item.isEnabled = isEnabled
        if let systemImage {
            item.image = NSImage(systemSymbolName: systemImage, accessibilityDescription: title)
        }
        if let identifier {
            item.identifier = NSUserInterfaceItemIdentifier(identifier)
        }
        return item
    }

    private func makeInfoItem(title: String) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.isEnabled = false
        return item
    }
}

private extension NSColor {
    static let anyBriefMark = NSColor(
        calibratedRed: 0.102,
        green: 0.102,
        blue: 0.102,
        alpha: 1.000
    )
}
