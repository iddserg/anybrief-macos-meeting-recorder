import SwiftUI

extension DashboardView {
    var recordingWorkspace: some View {
        activityWorkspace(viewModel.recordingActivity)
    }

    var processingWorkspace: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(spacing: 0) {
                    ForEach(viewModel.processingActivities, id: \.jobId) { activity in
                        activityContent(activity)
                        Divider()
                    }
                }
            }
            Divider()
            workspaceNavigationFooter(
                title: "You can start a new recording or browse other meetings while processing continues.",
                buttonTitle: "Meetings"
            ) {
                selectPane(.meetings)
            }
            .accessibilityIdentifier("processing.meetings")
        }
        .background(WorkspaceDesign.surface)
    }

    private func activityWorkspace(_ activity: DashboardViewModel.CurrentActivity?) -> some View {
        VStack(spacing: 0) {
            ScrollView { activityContent(activity) }
            if activity?.isRecording == true {
                Divider()
                workspaceNavigationFooter(title: "Processing and export", buttonTitle: "Configure") {
                    selectPane(.postProcessing)
                }
                .accessibilityIdentifier("recording.processing.configure")
            }
        }
        .background(WorkspaceDesign.surface)
    }

    private func activityContent(_ activity: DashboardViewModel.CurrentActivity?) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            if let activity {
                HStack(alignment: .top) {
                    VStack(alignment: .leading, spacing: 6) {
                        RecordingTitleView(viewModel: viewModel, activity: activity)
                        if !activity.isRecording {
                            Text(activity.startedAt, format: .dateTime.day().month().hour().minute())
                                .font(ABTypography.caption).foregroundStyle(ABDesign.secondaryText)
                        }
                    }
                    Spacer()
                    if activity.isRecording,
                       let autoStop = viewModel.recordingAutoStopState,
                       autoStop.isCalendarRecording,
                       !autoStop.isDisabled {
                        VStack(alignment: .trailing, spacing: 10) {
                            if let autoStopAt = autoStop.autoStopAt {
                                TimelineView(.periodic(from: .now, by: 1)) { context in
                                    Label {
                                        Text("Auto-stop in \(Self.recordingTime(autoStopAt.timeIntervalSince(context.date)))")
                                            .monospacedDigit()
                                    } icon: {
                                        Image(systemName: "timer")
                                    }
                                }
                                .font(ABTypography.captionMedium)
                                .foregroundStyle(ABDesign.secondaryText)
                            }
                            Button(action: viewModel.disableRecordingAutoStop) {
                                if viewModel.isDisablingRecordingAutoStop {
                                    ProgressView().controlSize(.small)
                                } else {
                                    Text("Disable auto-stop")
                                }
                            }
                            .buttonStyle(WorkspaceButtonStyle())
                            .disabled(viewModel.isDisablingRecordingAutoStop)
                            .accessibilityIdentifier("recording.autoStop.disable")
                        }
                    }
                }
                if let error = viewModel.recordingAutoStopError {
                    Text(error)
                        .font(ABTypography.caption)
                        .foregroundStyle(ABDesign.red)
                }
                Divider()
                if activity.isRecording {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Audio sources").font(ABTypography.itemTitle)
                        RecordingSourcesView(viewModel: viewModel, levels: viewModel.audioLevelStore)
                        Text(viewModel.isMicrophonePaused ? String(localized: "Microphone is paused. System audio is still recording.") : String(localized: "Your microphone and meeting audio are being recorded."))
                            .font(ABTypography.caption).foregroundStyle(ABDesign.secondaryText)
                    }
                    DisclosureGroup(isExpanded: $recordingPlanExpanded) {
                        VStack(alignment: .leading, spacing: 12) {
                            if let plan = viewModel.recordingProcessingPlan, plan.jobID == activity.jobId {
                                recordingOutputRow("Transcript", icon: "doc.text", detail: plan.transcriptDetail)
                                recordingOutputRow("Summary", icon: "text.alignleft", detail: plan.summaryDetail)
                                recordingOutputRow("Export", icon: "folder", detail: plan.exportDetail)
                                Text("Based on saved settings. Changes saved before processing can change this plan.")
                                    .font(ABTypography.caption).foregroundStyle(ABDesign.secondaryText)
                            } else {
                                ProgressView().controlSize(.small)
                            }
                        }.padding(.top, 8)
                    } label: {
                        HStack(spacing: 12) {
                            Text("After stopping").font(ABTypography.caption)
                                .foregroundStyle(ABDesign.secondaryText)
                            Text("Transcript → Summary → Export").font(ABTypography.bodyMedium)
                                .lineLimit(1)
                        }
                        .frame(maxWidth: .infinity, minHeight: 30, alignment: .leading)
                    }
                    .accessibilityIdentifier("recording.processingPlan")
                } else {
                    ProcessingStepsView(
                        activity: activity,
                        plan: viewModel.recordingProcessingPlan?.jobID == activity.jobId
                            ? viewModel.recordingProcessingPlan
                            : nil
                    )
                    .padding(.bottom, 8)
                }
            } else {
                WorkspaceEmptyState(icon: "waveform", title: String(localized: "Ready to record"), detail: String(localized: "Start a recording to capture your microphone and meeting audio."))
                    .frame(minHeight: 260)
                HStack { Spacer(); Button(action: viewModel.startRecording) { Label(viewModel.isStartingRecording ? String(localized: "Starting") : String(localized: "New recording"), systemImage: "record.circle") }.buttonStyle(WorkspaceButtonStyle(prominent: true)).disabled(!viewModel.canStartRecording); Spacer() }
                Button("Meetings") { selectPane(.meetings) }.buttonStyle(.plain).frame(maxWidth: .infinity)
            }
        }.padding(20).frame(maxWidth: 880, alignment: .leading).frame(maxWidth: .infinity)
    }

    func recordingOutputRow(_ title: LocalizedStringKey, icon: String, detail: String) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: icon).frame(width: 18, height: 20).foregroundStyle(ABDesign.secondaryText)
            VStack(alignment: .leading, spacing: 4) {
                Text(title).font(ABTypography.bodyMedium)
                Text(detail).font(ABTypography.caption).foregroundStyle(ABDesign.secondaryText)
                    .lineSpacing(2).textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }.frame(maxWidth: .infinity, alignment: .leading)
        }.frame(minHeight: 30, alignment: .topLeading)
    }

    var todayWorkspace: some View {
        VStack(spacing: 0) {
            AutopilotDayScheduleView(
                events: viewModel.todayAutopilotEvents,
                onSetAutopilotEnabled: viewModel.setAutopilotEnabled,
                onStartRecording: viewModel.startRecording(for:),
                canStartRecording: viewModel.canStartRecording(for:),
                recordingError: viewModel.calendarRecordingError,
                scheduleError: viewModel.calendarScheduleError
            )
            .padding(WorkspaceDesign.inset)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)

            Divider()
            workspaceNavigationFooter(title: "Calendar and Autopilot", buttonTitle: "Configure") {
                selectedSettingsCategory = .calendar
                selectPane(.settings)
            }
            .accessibilityIdentifier("calendar.settings")
        }
        .background(WorkspaceDesign.surface)
    }

    private func workspaceNavigationFooter(
        title: LocalizedStringKey,
        buttonTitle: LocalizedStringKey,
        action: @escaping () -> Void
    ) -> some View {
        HStack(spacing: 16) {
            Text(title)
                .font(ABTypography.caption)
                .foregroundStyle(ABDesign.secondaryText)
            Spacer(minLength: 0)
            Button(buttonTitle, action: action)
                .buttonStyle(WorkspaceButtonStyle())
        }
        .padding(.horizontal, WorkspaceDesign.inset)
        .padding(.vertical, 12)
    }
}

private struct ProcessingStepsView: View {
    enum State {
        case completed
        case current
        case pending
        case skipped
    }

    struct Step: Identifiable {
        let id: Int
        let title: LocalizedStringKey
        let icon: String
        let state: State
        let detail: String?
    }

    let activity: DashboardViewModel.CurrentActivity
    let plan: RecordingProcessingPlan?

    private var currentIndex: Int {
        switch JobStage(rawValue: activity.stage) {
        case .summarizing:
            return 1
        case .convertingAudio, .packaging, .completed, .partialSuccess:
            return 3
        default:
            return 0
        }
    }

    private var steps: [Step] {
        [
            Step(id: 0, title: "Transcript", icon: "doc.text", state: state(for: 0),
                 detail: currentIndex == 0 ? currentTranscriptDetail : nil),
            Step(id: 1, title: "Summary", icon: "text.alignleft",
                 state: plan?.summaryEnabled == false ? .skipped : state(for: 1),
                 detail: currentIndex == 1 ? currentDetail : nil),
            Step(id: 2, title: "Export", icon: "folder",
                 state: plan?.exportEnabled == false ? .skipped : state(for: 2),
                 detail: nil),
            Step(id: 3, title: "Preparing files", icon: "archivebox",
                 state: state(for: 3), detail: currentIndex == 3 ? currentDetail : nil),
        ]
    }

    private var currentDetail: String {
        if let fallback = activity.fallbackText {
            return "\(activity.detailedStageLabel)\n\(fallback)"
        }
        return activity.detailedStageLabel
    }

    private var currentTranscriptDetail: String {
        guard activity.stage == JobStage.transcribingSystem.rawValue
                || activity.stage == JobStage.transcribingMic.rawValue,
              let provider = plan?.transcriptDetail.split(separator: "\n").first else {
            return currentDetail
        }
        return "\(currentDetail) · \(provider)"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(alignment: .firstTextBaseline) {
                Text("Processing").font(ABTypography.sectionTitle)
                Spacer()
                Text(String(
                    format: String(localized: "Step %d of %d"),
                    currentIndex + 1,
                    steps.count
                ))
                .font(ABTypography.captionMedium)
                .foregroundStyle(ABDesign.secondaryText)
            }

            GeometryReader { proxy in
                ZStack(alignment: .leading) {
                    Capsule().fill(ABDesign.border)
                    Capsule()
                        .fill(ABDesign.accent)
                        .frame(width: proxy.size.width * progress)
                }
            }
            .frame(height: 8)

            VStack(alignment: .leading, spacing: 0) {
                ForEach(steps) { step in
                    HStack(alignment: .top, spacing: 14) {
                        VStack(spacing: 0) {
                            stepIndicator(step)
                            if step.id != steps.last?.id {
                                Rectangle()
                                    .fill(step.state == .completed ? ABDesign.green.opacity(0.55) : ABDesign.border)
                                    .frame(width: 2, height: 34)
                            }
                        }
                        VStack(alignment: .leading, spacing: 4) {
                            HStack(spacing: 8) {
                                Image(systemName: step.icon)
                                    .frame(width: 18)
                                    .foregroundStyle(step.state == .current ? ABDesign.accent : ABDesign.secondaryText)
                                Text(step.title).font(ABTypography.itemTitle)
                                Text(stateLabel(step.state))
                                    .font(ABTypography.badge)
                                    .foregroundStyle(stateColor(step.state))
                            }
                            if let detail = step.detail {
                                Text(detail)
                                    .font(ABTypography.caption)
                                    .foregroundStyle(ABDesign.secondaryText)
                                    .lineSpacing(2)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                        }
                        .padding(.top, 3)
                    }
                }
            }
        }
        .padding(18)
        .background(ABDesign.subtleBackground)
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(ABDesign.border))
        .accessibilityIdentifier("processing.steps")
    }

    private var progress: CGFloat {
        CGFloat(currentIndex + 1) / CGFloat(steps.count)
    }

    private func state(for index: Int) -> State {
        if index < currentIndex { return .completed }
        if index == currentIndex { return .current }
        return .pending
    }

    @ViewBuilder
    private func stepIndicator(_ step: Step) -> some View {
        ZStack {
            Circle()
                .fill(indicatorBackground(step.state))
                .overlay(Circle().stroke(indicatorBorder(step.state), lineWidth: 1.5))
            switch step.state {
            case .completed:
                Image(systemName: "checkmark").font(ABTypography.iconSmall).foregroundStyle(.white)
            case .current:
                ProgressView().controlSize(.mini).tint(ABDesign.accent)
            case .pending:
                Text("\(step.id + 1)").font(ABTypography.badge).foregroundStyle(ABDesign.secondaryText)
            case .skipped:
                Image(systemName: "minus").font(ABTypography.iconSmall).foregroundStyle(ABDesign.secondaryText)
            }
        }
        .frame(width: 26, height: 26)
    }

    private func indicatorBackground(_ state: State) -> Color {
        switch state {
        case .completed: return ABDesign.green
        case .current: return ABDesign.accent.opacity(0.10)
        case .pending, .skipped: return ABDesign.subtleBackground
        }
    }

    private func indicatorBorder(_ state: State) -> Color {
        switch state {
        case .completed: return ABDesign.green
        case .current: return ABDesign.accent
        case .pending, .skipped: return ABDesign.border
        }
    }

    private func stateColor(_ state: State) -> Color {
        switch state {
        case .completed: return ABDesign.green
        case .current: return ABDesign.accent
        case .pending, .skipped: return ABDesign.secondaryText
        }
    }

    private func stateLabel(_ state: State) -> LocalizedStringKey {
        switch state {
        case .completed: return "Done"
        case .current: return "In progress"
        case .pending: return "Waiting"
        case .skipped: return "Skipped"
        }
    }
}

private struct RecordingTitleView: View {
    @ObservedObject var viewModel: DashboardViewModel
    let activity: DashboardViewModel.CurrentActivity
    @State private var renaming = false
    @State private var titleDraft = ""
    @FocusState private var titleFocused: Bool

    private var meeting: DashboardViewModel.RecentMeeting? {
        viewModel.recentMeetings.first { $0.jobId == activity.jobId }
    }

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Text(meeting?.title ?? (activity.isRecording ? String(localized: "Current recording") : String(localized: "Recording in processing")))
                .font(ABTypography.pageTitle)
                .lineLimit(2)
            if activity.isRecording, let meeting {
                Button {
                    titleDraft = meeting.title
                    renaming = true
                } label: {
                    Image(systemName: "pencil").font(ABTypography.body)
                }
                .buttonStyle(WorkspaceButtonStyle())
                .help("Rename meeting")
                .accessibilityLabel("Rename meeting")
            }
        }
        .sheet(isPresented: $renaming) {
            VStack(alignment: .leading, spacing: 18) {
                Text("Rename meeting").font(ABTypography.sectionTitle)
                TextField("Name", text: $titleDraft)
                    .textFieldStyle(.roundedBorder)
                    .focused($titleFocused)
                    .onSubmit(saveTitle)
                HStack {
                    Spacer()
                    Button("Cancel") { renaming = false }.keyboardShortcut(.cancelAction)
                    Button("Save", action: saveTitle)
                        .keyboardShortcut(.defaultAction)
                        .disabled(titleDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || meeting == nil)
                }
            }
            .padding(24).frame(width: 400)
            .onAppear { titleFocused = true }
        }
    }

    private func saveTitle() {
        guard let meeting, !titleDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        viewModel.renameMeeting(meeting, title: titleDraft)
        renaming = false
    }
}

private struct RecordingSourcesView: View {
    @ObservedObject var viewModel: DashboardViewModel
    @ObservedObject var levels: AudioLevelStore
    var body: some View {
        Grid(alignment: .leading, horizontalSpacing: 14, verticalSpacing: 0) {
            GridRow {
                sourceIcon("mic")
                sourceTitle("Microphone")
                sourceSelector {
                    Picker("Microphone", selection: Binding(get: { viewModel.microphoneDeviceUID }, set: viewModel.selectMicrophoneDevice)) {
                        Text("Follow system input").tag("")
                        ForEach(viewModel.availableMicrophoneDevices) { Text($0.name).tag($0.uid) }
                        if !viewModel.microphoneDeviceUID.isEmpty, !viewModel.availableMicrophoneDevices.contains(where: { $0.uid == viewModel.microphoneDeviceUID }) {
                            Text("Unavailable microphone").tag(viewModel.microphoneDeviceUID)
                        }
                    }
                }
                signal(viewModel.isMicrophonePaused ? 0 : levels.levels.microphone, paused: viewModel.isMicrophonePaused)
                Button(action: viewModel.toggleMicrophonePause) {
                    Image(systemName: viewModel.isMicrophonePaused ? "mic.slash" : "mic")
                        .frame(width: 16)
                }
                .buttonStyle(WorkspaceButtonStyle())
                .disabled(viewModel.isUpdatingMicrophonePause)
                .help(viewModel.isMicrophonePaused ? Text("Resume Microphone") : Text("Pause Microphone"))
                .accessibilityIdentifier("toolbar.mic.toggle")
            }
            Divider().gridCellColumns(5).gridCellUnsizedAxes(.horizontal)
            GridRow {
                sourceIcon("speaker.wave.2")
                sourceTitle("System audio")
                sourceSelector {
                    Picker("System audio", selection: Binding(get: { viewModel.systemAudioApplicationBundleIdentifier }, set: viewModel.selectSystemAudioApplication)) {
                        Text("All system audio").tag("")
                        ForEach(viewModel.availableSystemAudioApplications) { Text($0.name).tag($0.bundleIdentifier) }
                        if !viewModel.systemAudioApplicationBundleIdentifier.isEmpty, !viewModel.availableSystemAudioApplications.contains(where: { $0.bundleIdentifier == viewModel.systemAudioApplicationBundleIdentifier }) {
                            Text("Unavailable application").tag(viewModel.systemAudioApplicationBundleIdentifier)
                        }
                    }
                }
                signal(levels.levels.system)
                Color.clear.frame(width: 40, height: 34)
            }
            Divider().gridCellColumns(5).gridCellUnsizedAxes(.horizontal)
        }
        .font(ABTypography.body)
        .controlSize(.regular)
    }

    private func sourceIcon(_ name: String) -> some View {
        Image(systemName: name).frame(width: 18)
    }

    private func sourceTitle(_ title: LocalizedStringKey) -> some View {
        Text(title).lineLimit(1).fixedSize(horizontal: true, vertical: false)
    }

    private func sourceSelector<Content: View>(@ViewBuilder content: @escaping () -> Content) -> some View {
        GeometryReader { geometry in
            content()
                .labelsHidden()
                .pickerStyle(.menu)
                .frame(width: min(360, geometry.size.width), alignment: .leading)
                .frame(maxHeight: .infinity, alignment: .leading)
        }
        .frame(height: 56)
        .frame(maxWidth: .infinity)
        .gridColumnAlignment(.leading)
    }

    private func signal(_ value: Double, paused: Bool = false) -> some View {
        VStack(spacing: 4) {
            HStack(alignment: .center, spacing: 3) {
                ForEach(0..<8) { index in
                    Capsule().fill(value > Double(index) / 10 ? ABDesign.green : ABDesign.hairline)
                        .frame(width: 4, height: CGFloat(6 + min(1, max(0, value)) * Double([10, 18, 24, 16, 22, 14, 20, 8][index])))
                }
            }.frame(height: 30)
            Text(paused ? String(localized: "Paused") : (value > 0.04 ? String(localized: "Signal") : String(localized: "Silent")))
                .font(ABTypography.caption).foregroundStyle(ABDesign.secondaryText)
                .lineLimit(1)
                .fixedSize(horizontal: true, vertical: false)
        }.frame(width: WorkspaceDesign.audioStatusWidth).accessibilityElement(children: .ignore)
            .accessibilityLabel(paused ? Text("Microphone is paused") : Text(value > 0.04 ? "Signal" : "Silent"))
    }
}
