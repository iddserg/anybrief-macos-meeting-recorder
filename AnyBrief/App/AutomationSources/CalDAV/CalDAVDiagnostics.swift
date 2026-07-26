import Foundation

/// CalDAV automation diagnostics.
struct CalDAVDiagnostics: AutomationDiagnostics {
    let keychainStore: SecretStoreProtocol

    func diagnose(configuration: AutomationSourceConfiguration, settings: AppSettings) async -> AutomationDiagnosticResult {
        guard settings.automation.calDAVSettings.enabled else {
            return AutomationDiagnosticResult(status: .failure, message: "CalDAV calendar is disabled.")
        }
        guard !settings.automation.calDAVSettings.config.url.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              !settings.automation.calDAVSettings.config.username.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              !settings.automation.calDAVSettings.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              settings.automation.calDAVSettings.passwordKeychainRef.flatMap({ keychainStore.load(key: $0) })?.isEmpty == false else {
            return AutomationDiagnosticResult(status: .failure, message: CalendarSyncError.missingConfiguration.localizedDescription)
        }
        return AutomationDiagnosticResult(status: .success, message: "CalDAV source is configured.")
    }
}
