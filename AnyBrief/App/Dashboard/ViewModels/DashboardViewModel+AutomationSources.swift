
import Foundation
import SwiftUI

extension DashboardViewModel {
    func automationSourceSettingsViewContext() -> AutomationSourceSettingsViewContext {
        AutomationSourceSettingsViewContext(
            settings: Binding(
                get: { self.automationSourceSettings },
                set: { self.automationSourceSettings = $0 }
            )
        )
    }
}
