import Foundation

/// Read-only calendar connection status for `/status` and `/permissions`.
/// Calendar data itself is not exposed through the Local HTTP API.
extension LocalAPIHandlers {
    func calendarConnectionRow() async -> [String: Any] {
        let settings = await appSettingsStore.load(using: loggingService)
        return [
            "kind": "calendar",
            "status": isCalendarConnected(settings) ? "granted" : "missing",
            "lastCheckedAt": NSNull(),
        ]
    }

    func isCalendarConnected(_ settings: AppSettings) -> Bool {
        settings.automation.calDAVSettings.enabled
            && !settings.automation.calDAVSettings.config.url.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !settings.automation.calDAVSettings.config.username.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && settings.automation.calDAVSettings.passwordKeychainRef.flatMap { keychainStore.load(key: $0) }?.isEmpty == false
    }
}
