import SwiftUI

extension CalDAVModule: DashboardAutomationSettingsProviding {
    @MainActor func makeDashboardSettingsView(viewModel: DashboardViewModel) -> AnyView {
        AnyView(CalDAVSettingsView(viewModel: viewModel))
    }
}
