
import SwiftUI

struct DashboardView: View {
    @ObservedObject var viewModel: DashboardViewModel
    @ObservedObject var notificationStore: InAppNotificationStore
    @State var selectedPane: Pane = .meetings
    @State var selectedMeetingID: String?
    @State var meetingSearch = ""
    @State var showingMeetingImport = false
    @State var recordingPlanExpanded = false
    @AppStorage("dashboard.meetingListWidth") var meetingListWidth = Double(WorkspaceDesign.listWidth)
    @State var meetingListDragStartWidth: CGFloat?
    @State var meetingListDividerHovered = false
    @State var templateTab = "prompts"
    @State var exportPreviewTitle = ""
    @State var lastActivityJobID: String?
    @State var selectedSettingsCategory: SettingsCategory = .app
    @State var selectedPostProcessingTab: PostProcessingTab = .summary
    @State var liveSettingsExpanded = false
    @State var recentExportsExpanded = false
    @State var transcriptionModelDetailsExpanded = false
    @State var transcriptionTechnologyDetailsExpanded = false
    @State var transcriptionVocabularyExpanded = false
    @State var transcriptionBasicSettingsExpanded = false
    @State var speakerSettingsExpanded = false
    @State var logAutoScrollDisabled = false
    @State var liveTranscriptDisplayState = LiveTranscriptTextDisplayState()
    @State var liveTranscriptStatusNow = Date()
    @State var liveTranscriptLeftColumnFraction: CGFloat = 0.5
    @State var liveTranscriptColumnDragStartFraction: CGFloat?

    let liveTranscriptCountdownTimer = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    private var selectedColorScheme: ColorScheme? {
        switch viewModel.appearanceSelection {
        case .light: return .light
        case .dark: return .dark
        case .system: return nil
        }
    }

    var body: some View {
        HStack(spacing: 0) {
            sidebar
                .fixedSize(horizontal: true, vertical: false)
                .layoutPriority(10)

            VStack(spacing: 0) {
                Group {
                    toolbar
                        .zIndex(10)
                    Divider()
                        .zIndex(9)
                }
                if [.meetings, .autopilot, .status].contains(selectedPane) {
                    RecordingSetupHintsView(viewModel: viewModel, open: openSetupDestination)
                }
                content
                    .zIndex(0)
            }
            .frame(minWidth: 0, maxWidth: .infinity, maxHeight: .infinity)
            .background(WorkspaceDesign.surface)
            .clipped()
            .layoutPriority(0)
        }
        .frame(minWidth: 900, minHeight: 580)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .tint(ABDesign.accent)
        .preferredColorScheme(selectedColorScheme)
        .onChange(of: viewModel.appearanceSelection, initial: true) { _, choice in
            AppAppearanceController.apply(choice)
        }
        .background(ABDesign.chromeBackground)
        .sheet(isPresented: $showingMeetingImport) {
            MeetingImportSheet(viewModel: viewModel) { jobID in
                lastActivityJobID = jobID
                if viewModel.processingActivities.contains(where: { $0.jobId == jobID }) {
                    selectPane(.processing)
                } else {
                    showCompletedMeeting(jobID)
                }
            }
        }
        .onChange(of: viewModel.effectiveAppState) { _, state in
            if state == .recording { selectPane(.status) }
        }
        .onChange(of: selectedMeetingID) { _, _ in
            viewModel.clearPostProcessingMessage()
        }
        .onChange(of: viewModel.recordingActivity?.jobId) { previous, current in
            recordingPlanExpanded = false
            if let current { lastActivityJobID = current }
            else if selectedPane == .status {
                if !viewModel.processingActivities.isEmpty {
                    selectPane(.processing)
                } else {
                    showCompletedMeeting(previous ?? lastActivityJobID)
                }
            }
        }
        .onChange(of: viewModel.processingActivities.map(\.jobId)) { previous, current in
            if current.isEmpty, selectedPane == .processing {
                showCompletedMeeting(previous.first)
            }
        }
        .onAppear {
            lastActivityJobID = viewModel.currentActivity?.jobId
            viewModel.setLiveTranscriptVisible(false)
            if viewModel.effectiveAppState == .recording { selectPane(.status) }
        }
    }

    func showCompletedMeeting(_ jobID: String?) {
        selectedMeetingID = viewModel.recentMeetings.first(where: { $0.jobId == jobID })?.id
        selectPane(.meetings)
    }

    func openSetupDestination(_ destination: SetupReadinessSectionView.Destination) {
        switch destination {
        case .permissions: selectPane(.permissions)
        case .transcription:
            selectedSettingsCategory = .transcription
            selectPane(.settings)
        case .llm:
            selectedSettingsCategory = .summary
            selectPane(.settings)
        case .processing:
            templateTab = "processing"
            selectedPostProcessingTab = .summary
            selectPane(.postProcessing)
        }
    }

    func selectPane(_ pane: Pane) {
        var targetPane = pane
        if targetPane == .liveTranscript {
            targetPane = .status
        }
        if selectedPane == .notifications, targetPane != .notifications {
            notificationStore.markAllAsRead()
        }
        selectedPane = targetPane
        viewModel.setLiveTranscriptVisible(false)
    }
}
