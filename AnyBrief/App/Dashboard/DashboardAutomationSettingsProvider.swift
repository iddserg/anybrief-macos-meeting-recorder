import SwiftUI

/// Optional bridge for automation sources that need richer Dashboard state than
/// the generic automation settings context currently exposes.
protocol DashboardAutomationSettingsProviding {
    @MainActor func makeDashboardSettingsView(viewModel: DashboardViewModel) -> AnyView
}
