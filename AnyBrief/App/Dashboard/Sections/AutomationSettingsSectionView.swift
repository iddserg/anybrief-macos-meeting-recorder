
import SwiftUI

extension DashboardView {
    @ViewBuilder
    var calendarAutopilotSettingsGroup: some View {
        if let provider = viewModel.automationSourceRegistry.modules.first(where: { $0.id == .calDAV })
            as? DashboardAutomationSettingsProviding {
            provider.makeDashboardSettingsView(viewModel: viewModel)
        }
    }
}
