import SwiftUI

/// One next step, ordered by what prevents the user from getting a recording first.
enum RecordingSetupHint: Equatable {
    case permissions, transcription, llm, automaticSummary, prompt

    init?(snapshot: SetupReadinessSnapshot) {
        if !snapshot.recordingPermissionsGranted { self = .permissions }
        else if snapshot.transcription.status == .failure { self = .transcription }
        else {
            switch snapshot.summary {
            case .noConnection: self = .llm
            case .disabled: self = .automaticSummary
            case .missingPrompt: self = .prompt
            case .configured: return nil
            }
        }
    }

    var message: String {
        switch self {
        case .permissions: return String(localized: "Allow microphone and screen recording access to capture your voice and meeting audio.")
        case .transcription: return String(localized: "Set up speech recognition to get a transcript. Audio recordings can be processed after setup.")
        case .llm: return String(localized: "Connect an LLM for meeting summaries. Recording and transcription can work without it.")
        case .automaticSummary: return String(localized: "Automatic summary is off. Turn it on to get meeting notes after recording.")
        case .prompt: return String(localized: "Select a summary prompt so AnyBrief knows how to prepare meeting notes.")
        }
    }

    var actionTitle: String {
        switch self {
        case .permissions: return String(localized: "Open permissions")
        case .transcription: return String(localized: "Set up transcription")
        case .llm: return String(localized: "Set up LLM")
        case .automaticSummary: return String(localized: "Set up automatic summary")
        case .prompt: return String(localized: "Choose prompt")
        }
    }

    var destination: SetupReadinessSectionView.Destination {
        switch self {
        case .permissions: return .permissions
        case .transcription: return .transcription
        case .llm: return .llm
        case .automaticSummary, .prompt: return .processing
        }
    }
}

enum ManualSummaryAvailability: Equatable {
    case noConnection, missingPrompt, ready

    init(settings: AppSettings, meetingTitle: String) {
        if settings.summaryLLMChain.isEmpty { self = .noConnection }
        else if settings.prompts.summaryPrompt(forMeetingTitle: meetingTitle)?.text
            .trimmingCharacters(in: .whitespacesAndNewlines).isEmpty != false { self = .missingPrompt }
        else { self = .ready }
    }
}

struct ContextualHintRow<Actions: View>: View {
    let message: String
    var isError = false
    @ViewBuilder let actions: () -> Actions

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: isError ? "exclamationmark.circle" : "info.circle")
                .foregroundStyle(isError ? ABDesign.red : ABDesign.accent).frame(width: 18, height: 18)
            VStack(alignment: .leading, spacing: 8) {
                Text(message).font(ABTypography.caption).foregroundStyle(ABDesign.secondaryText)
                    .fixedSize(horizontal: false, vertical: true)
                HStack(spacing: 16) { actions() }
                    .font(ABTypography.captionMedium).buttonStyle(.plain).foregroundStyle(ABDesign.accent)
            }.frame(maxWidth: .infinity, alignment: .leading)
        }.padding(12).background(WorkspaceDesign.secondarySurface)
            .clipShape(RoundedRectangle(cornerRadius: 8))
    }
}

struct RecordingSetupHintsView: View {
    @ObservedObject var viewModel: DashboardViewModel
    let open: (SetupReadinessSectionView.Destination) -> Void
    @State private var snapshot: SetupReadinessSnapshot?
    @State private var refreshID = UUID()

    var body: some View {
        Group {
            if !viewModel.isDownloadingTranscriptionModels, let snapshot, let hint = RecordingSetupHint(snapshot: snapshot) {
                ContextualHintRow(message: hint.message) {
                    Button(hint.actionTitle) { open(hint.destination) }
                        .accessibilityIdentifier("context.recording.configure")
                }.padding(.horizontal, WorkspaceDesign.inset).padding(.vertical, 10)
            }
        }
        .task(id: "\(viewModel.savedSettingsSignature ?? "")|\(viewModel.isDownloadingTranscriptionModels)|\(refreshID)") {
            guard viewModel.savedSettingsSignature != nil else { return }
            let result = await viewModel.loadSetupReadiness()
            guard !Task.isCancelled else { return }
            snapshot = result
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in refreshID = UUID() }
    }
}

/// A saved transcript can be summarized manually even when automatic summary is off.
struct MeetingSummaryGuidanceView: View {
    let meeting: DashboardViewModel.RecentMeeting
    let content: MeetingReaderContent
    let missingSummary: Bool
    @ObservedObject var viewModel: DashboardViewModel
    let open: (SetupReadinessSectionView.Destination) -> Void
    @State private var availability: ManualSummaryAvailability?

    private var busy: Bool {
        viewModel.resummarizingMeetingIds.contains(meeting.id) || viewModel.reprocessingMeetingIds.contains(meeting.id)
    }
    private var failed: Bool {
        content.hasSummaryFailure || (viewModel.summaryActionMeetingID == meeting.id && viewModel.summaryActionMessageIsError)
    }
    private var hasTranscript: Bool {
        content.transcriptError == nil && !content.transcript.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var body: some View {
        Group {
            if !busy, Job.isTerminalStatus(meeting.status), missingSummary || failed {
                if missingSummary {
                    GeometryReader { geometry in
                        ScrollView {
                            VStack(spacing: 14) {
                                Image(systemName: "doc.text").font(.system(size: 28, weight: .light))
                                    .foregroundStyle(ABDesign.secondaryText)
                                Text(title).font(ABTypography.itemTitle)
                                Text(detail).font(ABTypography.body).foregroundStyle(ABDesign.secondaryText)
                                    .multilineTextAlignment(.center).fixedSize(horizontal: false, vertical: true)
                                if availability != nil { actions.padding(.top, 4) }
                            }.padding(24).frame(maxWidth: .infinity)
                                .frame(minHeight: geometry.size.height)
                        }
                    }
                } else {
                    ContextualHintRow(message: String(localized: "The last summary attempt failed. Your saved materials are still available."), isError: true) {
                        actions
                    }.padding(.vertical, 12)
                }
            }
        }
        .task(id: "\(viewModel.savedSettingsSignature ?? "")|\(meeting.title)") {
            availability = nil
            let settings = await viewModel.appSettingsStore.load(using: viewModel.loggingService)
            guard !Task.isCancelled else { return }
            availability = ManualSummaryAvailability(settings: settings, meetingTitle: meeting.title)
        }
    }

    private var title: String {
        if !hasTranscript { return String(localized: "A transcript is needed first") }
        if failed { return String(localized: "Could not create summary") }
        if case .shortTranscript = content.summarySkipReason { return String(localized: "Summary was not created") }
        return String(localized: "Add a summary to this meeting")
    }

    private var detail: String {
        if !hasTranscript { return String(localized: "Create a transcript from the saved audio, then prepare a summary.") }
        if failed { return String(localized: "The last summary attempt failed. Your saved materials are still available.") }
        if case .shortTranscript = content.summarySkipReason, meeting.status == "completed" {
            return content.missingSummaryMessage(status: meeting.status)
        }
        switch availability {
        case .noConnection: return String(localized: "Connect an LLM, then create a summary from the saved transcript.")
        case .missingPrompt: return String(localized: "Choose a prompt to create a summary from the saved transcript.")
        case .ready: return String(localized: "The transcript is available. You can create a summary now, even if automatic summary is off.")
        case nil: return content.missingSummaryMessage(status: meeting.status)
        }
    }

    @ViewBuilder private var actions: some View {
        if !hasTranscript {
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 16) { transcriptActions }.fixedSize()
                VStack(spacing: 12) { transcriptActions }
            }.buttonStyle(WorkspaceButtonStyle())
        } else {
            switch availability {
            case .noConnection:
                Button("Set up LLM") { open(.llm) }.buttonStyle(WorkspaceButtonStyle())
            case .missingPrompt:
                Button("Choose prompt") { open(.processing) }.buttonStyle(WorkspaceButtonStyle())
            case .ready:
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 16) { summaryActions }.fixedSize()
                    VStack(alignment: .leading, spacing: 12) { summaryActions }
                }.buttonStyle(WorkspaceButtonStyle())
            case nil: EmptyView()
            }
        }
    }

    @ViewBuilder private var transcriptActions: some View {
        Button("Set up transcription") { open(.transcription) }
        Button("Repeat transcription") { viewModel.repeatMeetingProcessing(meeting, mode: .transcription) }
            .disabled(!viewModel.canRepeatMeetingProcessing(meeting))
    }

    @ViewBuilder private var summaryActions: some View {
        if failed { Button("Check LLM connection") { open(.llm) } }
        Button(failed ? String(localized: "Repeat summary") : String(localized: "Create summary")) {
            viewModel.repeatSummary(meeting)
        }.disabled(!viewModel.canRepeatSummary(meeting))
    }
}
