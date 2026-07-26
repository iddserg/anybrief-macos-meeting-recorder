
import Foundation
import SwiftUI

extension DashboardViewModel {
    var automationSourceModules: [any AutomationSourceModule] {
        automationSourceRegistry.modules.filter { $0.hasSettingsView }
    }

    func automationSourceSettingsViewContext() -> AutomationSourceSettingsViewContext {
        AutomationSourceSettingsViewContext(
            settings: Binding(
                get: { self.automationSourceSettings },
                set: { self.automationSourceSettings = $0 }
            )
        )
    }
}
