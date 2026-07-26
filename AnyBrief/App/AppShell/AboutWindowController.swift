import AppKit
import SwiftUI

/// About window showing app version, build number, and links.
@MainActor
final class AboutWindowController: NSWindowController, NSWindowDelegate {
    static let shared = AboutWindowController()

    private init() {
        let contentView = AboutView()
        let hostingController = NSHostingController(rootView: contentView)
        let window = NSWindow(contentViewController: hostingController)
        window.title = String(localized: "About AnyBrief")
        window.styleMask = [.titled, .closable]
        window.setContentSize(NSSize(width: 340, height: 260))
        window.isReleasedWhenClosed = false
        super.init(window: window)
        window.delegate = self
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func show() {
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func windowWillClose(_ notification: Notification) {
        // Keep the controller alive; next call to show() reuses it
    }
}

private struct AboutView: View {
    @State private var appVersion: String = ""

    // Determine the website based on the active language rather than
    // relying on localised string lookup (which can fail in debug builds
    // when the .xcstrings bundle is not yet embedded).
    private static var isRussian: Bool {
        let lang = (UserDefaults.standard.array(forKey: "AppleLanguages") as? [String])?.first
            ?? Locale.current.language.languageCode?.identifier
            ?? "en"
        return lang.hasPrefix("ru")
    }

    private static var websiteURL: URL {
        URL(string: isRussian ? "https://anybrief.ru" : "https://anybrief.pro")!
    }

    private static var websiteLabel: String {
        isRussian ? "anybrief.ru" : "anybrief.pro"
    }

    var body: some View {
        VStack(spacing: 16) {
            Image(nsImage: NSApp.applicationIconImage)
                .resizable()
                .frame(width: 96, height: 96)

            Text("AnyBrief", comment: "Application name in About window")
                .font(ABTypography.pageTitle)

            Text("Version \(appVersion)", comment: "Version display")
                .font(ABTypography.captionMedium)
                .foregroundStyle(.secondary)

            Link(Self.websiteLabel, destination: Self.websiteURL)
                .font(ABTypography.captionMedium)
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(nsColor: .windowBackgroundColor))
        .onAppear {
            appVersion = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "unknown"
        }
    }
}
