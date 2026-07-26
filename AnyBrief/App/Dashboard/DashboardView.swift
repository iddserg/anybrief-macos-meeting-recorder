
import SwiftUI

struct DashboardView: View {
    @ObservedObject var viewModel: DashboardViewModel
    @ObservedObject var notificationStore: InAppNotificationStore
    @State var selectedPane: Pane = .status
    @State var selectedSettingsCategory: SettingsCategory = .summary
    @State var selectedPostProcessingTab: PostProcessingTab = .summary
    @State var liveSettingsExpanded = false
    @State var recentSummariesExpanded = false
    @State var transcriptionModelDetailsExpanded = false
    @State var transcriptionTechnologyDetailsExpanded = false
    @State var transcriptionVocabularyExpanded = false
    @State var microphoneSettingsExpanded = false
    @State var speakerSettingsExpanded = false
    @State var logAutoScrollDisabled = false
    @State var liveTranscriptDisplayState = LiveTranscriptTextDisplayState()
    @State var liveTranscriptStatusNow = Date()
    @State var liveTranscriptLeftColumnFraction: CGFloat = 0.5
    @State var liveTranscriptColumnDragStartFraction: CGFloat?

    let liveTranscriptCountdownTimer = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    var body: some View {
        HStack(spacing: 0) {
            sidebar
                .fixedSize(horizontal: true, vertical: false)
                .layoutPriority(10)

            VStack(spacing: 0) {
                if selectedPane != .settings && selectedPane != .logs {
                    toolbar
                        .zIndex(10)
                    Divider()
                        .zIndex(9)
                }
                content
                    .zIndex(0)
            }
            .frame(minWidth: 0, maxWidth: .infinity, maxHeight: .infinity)
            .background(ABDesign.contentBackground)
            .clipped()
            .layoutPriority(0)
        }
        .frame(minWidth: 900, minHeight: 580)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .tint(ABDesign.accent)
        .preferredColorScheme(.light)
        .background(ABDesign.chromeBackground)
        .onChange(of: notificationStore.unreadCount) { _ in
            markNotificationsAsReadIfNeeded()
        }
        .onChange(of: viewModel.liveTranscriptEnabled) { enabled in
            if !enabled, selectedPane == .liveTranscript {
                selectPane(.status)
            } else {
                viewModel.setLiveTranscriptVisible(enabled && selectedPane == .liveTranscript)
            }
        }
    }

    func selectPane(_ pane: Pane) {
        var targetPane = pane
        if targetPane == .liveTranscript && !viewModel.liveTranscriptEnabled {
            targetPane = .status
        }
        if selectedPane != .notifications, targetPane == .notifications {
            notificationStore.removeReadNotifications()
        }
        selectedPane = targetPane
        viewModel.setLiveTranscriptVisible(targetPane == .liveTranscript)
        markNotificationsAsReadIfNeeded()
    }

    func markNotificationsAsReadIfNeeded() {
        guard selectedPane == .notifications, notificationStore.unreadCount > 0 else {
            return
        }
        notificationStore.markAllAsRead()
    }
}
