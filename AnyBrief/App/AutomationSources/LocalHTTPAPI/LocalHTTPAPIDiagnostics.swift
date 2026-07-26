import Foundation

struct LocalHTTPAPIDiagnostics: AutomationDiagnostics {
    let keychainStore: SecretStoreProtocol

    func diagnose(configuration: AutomationSourceConfiguration, settings: AppSettings) async -> AutomationDiagnosticResult {
        guard settings.automation.localHTTPAPISettings.enabled else {
            return AutomationDiagnosticResult(status: .failure, message: "Local HTTP API is disabled.")
        }
        guard (1...65_535).contains(settings.automation.localHTTPAPISettings.port) else {
            return AutomationDiagnosticResult(status: .failure, message: "Local HTTP API port is invalid.")
        }
        guard settings.automation.localHTTPAPISettings.apiKeyKeychainRef.flatMap({ keychainStore.load(key: $0) })?.isEmpty == false else {
            return AutomationDiagnosticResult(status: .failure, message: "Local HTTP API key is missing.")
        }
        return AutomationDiagnosticResult(status: .success, message: "Local HTTP API source is configured.")
    }
}
