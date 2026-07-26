import AppKit
import Foundation

@MainActor
enum AppRelaunchPrompt {
    static func offerForLanguageChange(onLater: (() -> Void)? = nil) {
        let alert = NSAlert()
        alert.alertStyle = .informational
        alert.messageText = String(localized: "Restart AnyBrief?")
        alert.informativeText = String(
            localized: "The language change will apply after restarting the app."
        )
        alert.addButton(withTitle: String(localized: "Restart Now"))
        alert.addButton(withTitle: String(localized: "Later"))

        if alert.runModal() == .alertFirstButtonReturn {
            relaunchAfterCurrentInstanceQuits()
        } else {
            onLater?()
        }
    }

    private static func relaunchAfterCurrentInstanceQuits() {
        let executablePath = CommandLine.arguments.first ?? Bundle.main.executablePath ?? ""
        NSLog("AnyBrief language relaunch executable: \(executablePath)")
        let script = "sleep 0.8; \(shellQuoted(executablePath))"
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/bin/sh")
        task.arguments = ["-c", script]
        try? task.run()
        NSApp.terminate(nil)
    }

    private static func shellQuoted(_ value: String) -> String {
        "'\(value.replacingOccurrences(of: "'", with: "'\\''"))'"
    }
}
