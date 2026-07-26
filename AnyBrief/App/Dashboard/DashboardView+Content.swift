import SwiftUI

extension DashboardView {
    @ViewBuilder
    var content: some View {
        if selectedPane == .settings {
            GeometryReader { proxy in
                ScrollView {
                    contentBody
                        .frame(minHeight: proxy.size.height, alignment: .topLeading)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        } else if selectedPane == .meetings || selectedPane == .notifications
            || (selectedPane == .postProcessing && selectedPostProcessingTab == .export) {
            ScrollView {
                contentBody
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        } else {
            contentBody
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                .clipped()
        }
    }

    @ViewBuilder
    var contentBody: some View {
        switch selectedPane {
        case .status:
            GeometryReader { proxy in
                contentStack(fillsHeight: true) {
                    currentActivitySection
                    recentMeetingsSection(
                        limit: statusRecentMeetingsLimit(for: proxy.size.height),
                        showsMoreButton: true
                    )
                }
            }
        case .logs:
            contentStack(fillsHeight: true) {
                logsSection
            }
        case .liveTranscript:
            contentStack(fillsHeight: true) {
                if viewModel.liveTranscriptEnabled {
                    liveTranscriptSection
                } else {
                    currentActivitySection
                }
            }
        default:
            contentStack(
                fillsHeight: selectedPane == .autopilot
                    || (selectedPane == .postProcessing && selectedPostProcessingTab != .export)
            ) {
                switch selectedPane {
                case .status:
                    EmptyView()
                case .liveTranscript:
                    EmptyView()
                case .prompts:
                    promptsSection
                case .meetings:
                    recentMeetingsSection(limit: nil, showsMoreButton: false)
                case .postProcessing:
                    postProcessingSection
                case .autopilot:
                    autopilotSection
                case .notifications:
                    notificationsSection
                case .settings:
                    settingsSection
                case .logs:
                    EmptyView()
                case .permissions:
                    permissionsSection
                }
            }
        }
    }

    func contentStack<Content: View>(
        fillsHeight: Bool = false,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            content()
        }
        .padding(.horizontal, 18)
        .padding(.top, 14)
        .padding(.bottom, 18)
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
