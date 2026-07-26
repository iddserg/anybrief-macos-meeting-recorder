import Foundation
import SwiftUI

struct WindowObserverModule: AutomationSourceModule {
    let id: AutomationSourceID = .windowObserver
    let title = "Window Observer"
    let systemImage = "macwindow.badge.record"
    let hasSettingsView = true

    func defaultConfiguration() -> AutomationSourceConfiguration {
        AutomationSourceConfiguration(source: id)
    }

    func makeSource(context: AutomationRuntimeContext) -> any AutomationSource {
        WindowObserverSource(
            appSettingsStore: context.appSettingsStore,
            loggingService: context.loggingService,
            currentSessionProvider: context.currentSessionProvider,
            sleep: context.sleep
        )
    }

    func makeDiagnostics(context: AutomationDiagnosticsContext) -> any AutomationDiagnostics {
        WindowObserverDiagnostics()
    }

    @MainActor func makeSettingsView(context: AutomationSourceSettingsViewContext) -> AnyView {
        AnyView(WindowObserverSettingsView(settings: context.settings))
    }
}

struct WindowObserverDiagnostics: AutomationDiagnostics {
    func diagnose(configuration: AutomationSourceConfiguration, settings: AppSettings) async -> AutomationDiagnosticResult {
        let config = settings.automation.windowObserverSettings.normalized()
        guard config.enabled else {
            return AutomationDiagnosticResult(status: .failure, message: "Window Observer is disabled.")
        }
        guard config.rules.contains(where: { rule in
            let normalized = rule.normalized
            return normalized.enabled && (!normalized.applicationPattern.isEmpty || !normalized.titlePattern.isEmpty)
        }) else {
            return AutomationDiagnosticResult(status: .failure, message: "Add at least one enabled window match rule.")
        }
        return AutomationDiagnosticResult(status: .success, message: "Window Observer is configured.")
    }
}
