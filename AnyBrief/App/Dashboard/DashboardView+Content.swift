import SwiftUI

extension DashboardView {
    @ViewBuilder
    var content: some View {
        switch selectedPane {
        case .meetings:
            meetingsWorkspace
        case .status, .liveTranscript:
            recordingWorkspace
        case .processing:
            processingWorkspace
        case .postProcessing, .prompts:
            templatesWorkspace
        case .autopilot:
            todayWorkspace
        case .settings:
            settingsSection
        case .setup:
            SetupReadinessSectionView(viewModel: viewModel, open: openSetupDestination)
        case .notifications:
            contentStack(fillsHeight: true) { notificationsSection }
        case .permissions:
            ScrollView { contentStack { permissionsSection } }
        case .logs:
            contentStack(fillsHeight: true, topInset: 12) { logsSection }
        }
    }

    func contentStack<Content: View>(
        fillsHeight: Bool = false,
        topInset: CGFloat = WorkspaceDesign.inset,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            content()
        }
        .padding(.horizontal, WorkspaceDesign.inset)
        .padding(.top, topInset)
        .padding(.bottom, WorkspaceDesign.inset)
        .frame(
            maxWidth: .infinity,
            maxHeight: fillsHeight ? .infinity : nil,
            alignment: .topLeading
        )
    }

    func statusRecentMeetingsLimit(for availableHeight: CGFloat) -> Int {
        let minimumRows = 3
        let rowHeight: CGFloat = 39
        let baseHeight: CGFloat = viewModel.currentActivity == nil ? 520 : 650
        let extraRows = max(0, Int((availableHeight - baseHeight) / rowHeight))
        let availableRows = minimumRows + extraRows

        return min(max(minimumRows, availableRows), max(minimumRows, viewModel.recentMeetings.count))
    }
}
