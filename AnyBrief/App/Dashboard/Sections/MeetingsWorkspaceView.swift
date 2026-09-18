import SwiftUI
import MarkdownUI

extension DashboardView {
    var filteredMeetings: [DashboardViewModel.RecentMeeting] {
        let query = meetingSearch.trimmingCharacters(in: .whitespacesAndNewlines)
        return viewModel.recentMeetings.filter { query.isEmpty || $0.title.localizedCaseInsensitiveContains(query) }
    }

    var meetingsWorkspace: some View {
        GeometryReader { geometry in
            HStack(spacing: 0) {
                VStack(spacing: 0) {
                    HStack(spacing: 6) {
                        Image(systemName: "magnifyingglass").foregroundStyle(ABDesign.secondaryText)
                        TextField("Find a meeting", text: $meetingSearch).textFieldStyle(.plain)
                            .accessibilityIdentifier("meetings.search")
                    }.font(ABTypography.body).padding(10).background(WorkspaceDesign.surface)
                        .clipShape(RoundedRectangle(cornerRadius: 7)).padding(12)
                    ScrollView {
                        LazyVStack(spacing: WorkspaceDesign.listRowSpacing) {
                            ForEach(filteredMeetings) { meeting in
                                meetingListItem(meeting)
                            }
                        }.padding(.horizontal, 10)
                    }
                    Divider()
                    Button(action: viewModel.openMeetingsFolder) { Label("Open Folder", systemImage: "folder") }
                        .buttonStyle(.plain).font(ABTypography.caption).padding(16)
                }
                .frame(width: clampedMeetingListWidth(meetingListWidth, availableWidth: geometry.size.width))
                .background(WorkspaceDesign.secondarySurface)
                meetingListDivider(availableWidth: geometry.size.width)
                    .zIndex(1)
                if let meeting = filteredMeetings.first(where: { $0.id == selectedMeetingID }) ?? filteredMeetings.first {
                    MeetingReaderView(meeting: meeting, viewModel: viewModel, openSetup: openSetupDestination,
                                      openCurrentRecording: { selectPane(.status) })
                        .id(meeting.id)
                } else {
                    WorkspaceEmptyState(icon: "doc.text.magnifyingglass", title: String(localized: "No meetings found"),
                                        detail: meetingSearch.isEmpty ? String(localized: "Your recordings and their materials will appear here.") : String(localized: "Try a different meeting title."))
                }
            }.background(WorkspaceDesign.surface)
        }
    }

    private func clampedMeetingListWidth(_ proposed: CGFloat, availableWidth: CGFloat) -> CGFloat {
        let maximum = max(200, min(420, availableWidth - 421))
        return min(maximum, max(200, proposed.isFinite ? proposed : WorkspaceDesign.listWidth))
    }

    private func meetingListDivider(availableWidth: CGFloat) -> some View {
        Rectangle().fill(ABDesign.hairline).frame(width: 1)
            .overlay {
                Color.clear.frame(width: 9).contentShape(Rectangle())
                    .onHover { hovering in
                        guard hovering != meetingListDividerHovered else { return }
                        meetingListDividerHovered = hovering
                        if hovering { NSCursor.resizeLeftRight.push() } else { NSCursor.pop() }
                    }
                    .onDisappear {
                        if meetingListDividerHovered { NSCursor.pop(); meetingListDividerHovered = false }
                        meetingListDragStartWidth = nil
                    }
                    .gesture(
                        DragGesture(minimumDistance: 0, coordinateSpace: .global)
                            .onChanged { value in
                                if meetingListDragStartWidth == nil {
                                    meetingListDragStartWidth = clampedMeetingListWidth(meetingListWidth, availableWidth: availableWidth)
                                }
                                meetingListWidth = clampedMeetingListWidth(
                                    (meetingListDragStartWidth ?? meetingListWidth) + value.translation.width,
                                    availableWidth: availableWidth)
                            }
                            .onEnded { _ in meetingListDragStartWidth = nil }
                    )
                    .accessibilityLabel(Text("Resize meeting list"))
                    .accessibilityIdentifier("meetings.list.resize")
                    .accessibilityAdjustableAction { direction in
                        let width = clampedMeetingListWidth(meetingListWidth, availableWidth: availableWidth)
                        switch direction {
                        case .increment: meetingListWidth = clampedMeetingListWidth(width + 20, availableWidth: availableWidth)
                        case .decrement: meetingListWidth = clampedMeetingListWidth(width - 20, availableWidth: availableWidth)
                        @unknown default: break
                        }
                    }
            }
    }

    func meetingListItem(_ meeting: DashboardViewModel.RecentMeeting) -> some View {
        let selected = meeting.id == (filteredMeetings.first(where: { $0.id == selectedMeetingID }) ?? filteredMeetings.first)?.id
        return VStack(alignment: .leading, spacing: WorkspaceDesign.listDetailSpacing) {
            Text(meeting.title).font(ABTypography.bodyMedium).lineLimit(2)
            HStack(spacing: 6) {
                if let date = meeting.timestamp { Text(date, format: .dateTime.day().month().hour().minute()) }
                Spacer(minLength: 0)
                if meeting.status != "completed" {
                    MeetingListStatusButton(status: meeting.status)
                }
            }.font(ABTypography.caption).foregroundStyle(ABDesign.secondaryText)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, WorkspaceDesign.listRowVerticalInset)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(selected ? WorkspaceDesign.surface : Color.clear)
        .clipShape(RoundedRectangle(cornerRadius: 7))
        .contentShape(Rectangle())
        .onTapGesture { selectedMeetingID = meeting.id }
        .accessibilityAddTraits(.isButton)
        .accessibilityAddTraits(selected ? .isSelected : [])
        .accessibilityAction { selectedMeetingID = meeting.id }
    }
}

private struct MeetingListStatusButton: View {
    let status: String
    @State private var isPresented = false

    private var label: String {
        DashboardStatusLabels.label(for: status)
    }

    var body: some View {
        Button {
            isPresented.toggle()
        } label: {
            Image(systemName: status == "recording" ? "record.circle" : "circle.dotted")
                .frame(width: 20, height: 20)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(label)
        .popover(isPresented: $isPresented, arrowEdge: .top) {
            Text(label)
                .font(ABTypography.tooltip)
                .foregroundStyle(ABDesign.primaryText)
                .padding(10)
                .frame(width: 220, alignment: .leading)
        }
        .accessibilityLabel(Text(label))
        .accessibilityHint(Text(String(localized: "Show help")))
    }
}

private enum MeetingMaterial: String, CaseIterable {
    case summary, transcript, audio, technical
    var title: String {
        switch self {
        case .summary: return String(localized: "Summary")
        case .transcript: return String(localized: "Transcript")
        case .audio: return String(localized: "Audio")
        case .technical: return String(localized: "Technical details")
        }
    }
}

struct MeetingReaderView: View {
    let meeting: DashboardViewModel.RecentMeeting
    @ObservedObject var viewModel: DashboardViewModel
    let openSetup: (SetupReadinessSectionView.Destination) -> Void
    let openCurrentRecording: () -> Void
    @StateObject private var reader = MeetingReaderModel()
    @State private var material: MeetingMaterial = .summary
    @State private var renaming = false
    @State private var titleDraft = ""
    @State private var skipMicrophone = false
    @State private var processingPreferenceError: String?
    private let timer = Timer.publish(every: 0.3, on: .main, in: .common).autoconnect()

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .top, spacing: 12) {
                VStack(alignment: .leading, spacing: 8) {
                    Text(meeting.title).font(ABTypography.pageTitle).textSelection(.enabled)
                    HStack(spacing: 10) {
                        if let date = meeting.timestamp { Text(date, format: .dateTime.day().month().year().hour().minute()) }
                        Text(DashboardStatusLabels.label(for: meeting.status))
                    }.font(ABTypography.caption).foregroundStyle(ABDesign.secondaryText)
                }
                Spacer(minLength: 0)
                Menu {
                    Button("Rename") { titleDraft = meeting.title; renaming = true }
                    Button("Open Summary") { viewModel.openPrimaryMeetingDocument(meeting) }.disabled(meeting.summaryURL == nil)
                    Button("Open Transcript") { viewModel.openTranscript(meeting) }.disabled(!viewModel.canOpenTranscript(meeting))
                    Button("Open Folder") { viewModel.showInFinder(meeting) }
                    Button("Export") { viewModel.exportMeeting(meeting) }.disabled(!viewModel.hasExportableArtifacts(meeting))
                    Button("Open export folder") { viewModel.openExportPath(meeting) }.disabled(!viewModel.canOpenExportPath(meeting))
                    Divider()
                    Button("Repeat summary") { viewModel.repeatSummary(meeting) }
                        .disabled(!viewModel.canRepeatSummary(meeting))
                    Button("Repeat transcription") { viewModel.repeatMeetingProcessing(meeting, mode: .transcription) }
                        .disabled(!viewModel.canRepeatMeetingProcessing(meeting))
                    Button("Repeat all") { viewModel.repeatMeetingProcessing(meeting, mode: .all) }.disabled(!viewModel.canRepeatMeetingProcessing(meeting))
                    Divider()
                    Button("Delete", role: .destructive) { viewModel.deleteMeeting(meeting) }.disabled(!meeting.canDelete)
                } label: { Image(systemName: "ellipsis").frame(width: 24, height: 28) }
                .menuStyle(.borderlessButton).frame(width: 30)
            }.padding(.bottom, 20)
            HStack(spacing: 22) {
                ForEach(MeetingMaterial.allCases, id: \.self) { tab in
                    WorkspaceTab(title: tab.title, selected: material == tab) { material = tab }
                }
                Spacer(minLength: 0)
                if material != .audio {
                    Button {
                        viewModel.copyToPasteboard(copyableMaterial)
                    } label: { Image(systemName: "doc.on.doc") }
                    .buttonStyle(.plain).help(Text("Copy"))
                    .disabled(reader.loading || copyableMaterial.isEmpty)
                    .accessibilityLabel(Text("Copy"))
                }
            }
            Divider()
            VStack(alignment: .leading, spacing: 0) {
                if isMaterialProcessing {
                    HStack(spacing: 8) {
                        ProgressView()
                            .controlSize(.small)
                            .frame(width: 16, height: 16)
                        Text("Preparing meeting materials…")
                            .font(ABTypography.caption)
                            .foregroundStyle(ABDesign.secondaryText)
                    }
                    .frame(maxWidth: .infinity, minHeight: 24, alignment: .leading)
                    .padding(.top, 12)
                }
                materialContent.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            }
            Divider()
            HStack(spacing: 8) {
                Image(systemName: "folder")
                Text(meeting.folderURL.lastPathComponent).lineLimit(1).truncationMode(.middle)
                Spacer()
                Button("Show in Finder") { viewModel.showInFinder(meeting) }.buttonStyle(.plain)
            }.font(ABTypography.caption).foregroundStyle(ABDesign.secondaryText).padding(.top, 14)
            if viewModel.summaryActionMeetingID == meeting.id, let message = viewModel.summaryActionMessage {
                Text(message).font(ABTypography.caption).foregroundStyle(viewModel.summaryActionMessageIsError ? ABDesign.red : ABDesign.green).padding(.top, 8)
            }
            if let message = viewModel.postProcessingMessage(for: meeting.id) {
                Text(message).font(ABTypography.caption).foregroundStyle(viewModel.postProcessingMessageIsError ? ABDesign.red : ABDesign.green).padding(.top, 8)
            }
        }
        .padding(WorkspaceDesign.inset)
        .task(id: "\(meeting.folderURL.path)|\(meeting.status)|\(meeting.summaryURL?.path ?? "")|\(material.rawValue)|\(viewModel.resummarizingMeetingIds.contains(meeting.id))|\(viewModel.reprocessingMeetingIds.contains(meeting.id))") {
            skipMicrophone = MeetingMetadataStore.skipsMicrophone(in: meeting.folderURL)
            processingPreferenceError = nil
            await reader.load(meeting, jobLogURL: viewModel.jobLogURL(for: meeting))
            if !Task.isCancelled, material == .audio { await reader.loadAudio(folder: meeting.folderURL) }
        }
        .onReceive(timer) { _ in reader.tick() }
        .onDisappear { reader.stop() }
        .sheet(isPresented: $renaming) {
            VStack(alignment: .leading, spacing: 18) {
                Text("Rename meeting").font(ABTypography.sectionTitle)
                TextField("Name", text: $titleDraft).textFieldStyle(.roundedBorder).onSubmit(saveTitle)
                HStack { Spacer(); Button("Cancel") { renaming = false }; Button("Save", action: saveTitle).keyboardShortcut(.defaultAction).disabled(titleDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty) }
            }.padding(24).frame(width: 400)
        }
    }

    private var isMaterialProcessing: Bool {
        guard meeting.status != "recording", material == .summary || material == .transcript else { return false }
        return viewModel.reprocessingMeetingIds.contains(meeting.id)
            || !Job.isTerminalStatus(meeting.status)
            || (material == .summary && viewModel.resummarizingMeetingIds.contains(meeting.id))
    }

    @ViewBuilder private var materialContent: some View {
        if meeting.status == "recording", material == .summary || material == .transcript {
            VStack(spacing: 12) {
                Image(systemName: "record.circle")
                    .font(.system(size: 28, weight: .light)).foregroundStyle(ABDesign.red)
                Text("Recording in progress").font(ABTypography.itemTitle)
                Text("The transcript and summary will appear after recording stops and processing finishes.")
                    .font(ABTypography.body).foregroundStyle(ABDesign.secondaryText)
                    .multilineTextAlignment(.center).frame(maxWidth: 420)
                Button(action: openCurrentRecording) {
                    Label("Go to current recording", systemImage: "waveform")
                }
                .buttonStyle(WorkspaceButtonStyle())
                .accessibilityIdentifier("meeting.openCurrentRecording")
            }
            .padding(24).frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if reader.loading {
            if isMaterialProcessing { Color.clear }
            else { ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity) }
        }
        else if material == .audio { audioContent }
        else if material == .technical { technicalContent }
        else {
            let text = material == .summary ? DashboardViewModel.markdownWithoutFrontmatter(reader.content.summary) : reader.content.transcript
            let error = material == .summary ? reader.content.summaryError : reader.content.transcriptError
            if let error {
                WorkspaceEmptyState(icon: "exclamationmark.triangle", title: String(localized: "Could not read material"), detail: error)
            } else if text.isEmpty {
                if material == .summary, !isMaterialProcessing, Job.isTerminalStatus(meeting.status) {
                    summaryGuidance(missing: true)
                } else {
                    WorkspaceEmptyState(icon: "doc.text", title: String(localized: "Material is not ready"), detail: String(localized: "It will appear here after processing. You can also repeat processing from the meeting menu."))
                }
            } else {
                ScrollView {
                    if material == .summary {
                        VStack(alignment: .leading, spacing: 12) {
                            summaryGuidance(missing: false)
                            MeetingMarkdownView(text: text)
                        }
                    }
                    else { Text(text).font(ABTypography.body).lineSpacing(6).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading) }
                }.padding(.vertical, 22)
            }
        }
    }

    private func summaryGuidance(missing: Bool) -> some View {
        MeetingSummaryGuidanceView(meeting: meeting, content: reader.content, missingSummary: missing,
                                   viewModel: viewModel, open: openSetup)
    }

    private var copyableMaterial: String {
        switch material {
        case .summary: return DashboardViewModel.markdownWithoutFrontmatter(reader.content.summary)
        case .transcript: return reader.content.transcript
        case .technical: return reader.content.technicalDetails.copyText
        case .audio: return ""
        }
    }

    @ViewBuilder private var technicalContent: some View {
        let details = reader.content.technicalDetails
        if let error = reader.content.summaryError {
            WorkspaceEmptyState(icon: "exclamationmark.triangle", title: String(localized: "Could not read material"), detail: error)
        } else if details.sections.isEmpty {
            WorkspaceEmptyState(icon: "info.circle", title: String(localized: "Technical details unavailable"),
                detail: String(localized: "This meeting has no saved technical metadata in its summary."))
        } else {
            ScrollView {
                VStack(alignment: .leading, spacing: 28) {
                    ForEach(details.sections) { section in
                        VStack(alignment: .leading, spacing: 14) {
                            Text(section.title).font(ABTypography.itemTitle)
                            Grid(alignment: .topLeading, horizontalSpacing: 24, verticalSpacing: 12) {
                                ForEach(section.rows) { row in
                                    GridRow {
                                        Text(row.title).foregroundStyle(ABDesign.secondaryText)
                                            .frame(width: 190, alignment: .leading)
                                        Text(row.value).frame(maxWidth: .infinity, alignment: .leading)
                                    }
                                }
                            }.font(ABTypography.body)
                        }
                    }
                }
                .textSelection(.enabled)
                .padding(.vertical, 24)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    @ViewBuilder private var audioContent: some View {
        if reader.audioLoading { ProgressView("Preparing audio…").padding(.top, 30) }
        else if let error = reader.audioError { WorkspaceEmptyState(icon: "waveform", title: String(localized: "Audio unavailable"), detail: error) }
        else {
            VStack(alignment: .leading, spacing: 24) {
                if reader.audioSources.count > 1 {
                    Picker("Audio source", selection: Binding(get: { reader.selectedAudioSource }, set: reader.selectAudioSource)) {
                        ForEach(reader.audioSources) { source in
                            Text(source.title).tag(source)
                        }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .frame(maxWidth: 440)
                    .accessibilityIdentifier("meeting.audio.source")
                } else if let source = reader.audioSources.first {
                    Text(reader.content.isImported ? String(localized: "Imported audio") : source.title).font(ABTypography.bodyMedium)
                }
                HStack(spacing: 16) {
                    Button(action: reader.togglePlayback) {
                        Image(systemName: reader.playing ? "pause.fill" : "play.fill")
                    }.buttonStyle(WorkspaceButtonStyle()).disabled(reader.duration <= 0)
                        .accessibilityLabel(reader.playing ? Text("Pause") : Text("Play"))
                    Slider(value: Binding(get: { reader.position }, set: reader.seek), in: 0...max(1, reader.duration))
                        .accessibilityLabel(Text("Playback position"))
                    Text("\(DashboardView.recordingTime(reader.position)) / \(DashboardView.recordingTime(reader.duration))")
                        .font(ABTypography.caption).monospacedDigit()
                }
                if reader.audioSources.contains(.microphone) {
                    VStack(alignment: .trailing, spacing: 8) {
                        HStack(spacing: 6) {
                            Toggle("Do not process microphone", isOn: Binding(get: { skipMicrophone }, set: saveMicrophonePreference))
                                .toggleStyle(.checkbox).controlSize(.small)
                                .disabled(!canChangeProcessingPreference)
                                .accessibilityIdentifier("meeting.processing.skipMicrophone")
                            HelpTooltipIcon(
                                text: String(localized: "Applies to this meeting when repeating transcription or all processing. Microphone audio stays available for playback.")
                            )
                            .accessibilityIdentifier("meeting.processing.skipMicrophone.help")
                        }
                        Button {
                            viewModel.repeatMeetingProcessing(meeting, mode: .all)
                        } label: {
                            Label("Repeat all", systemImage: "arrow.triangle.2.circlepath")
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                        .disabled(!viewModel.canRepeatMeetingProcessing(meeting))
                        .accessibilityIdentifier("meeting.processing.repeatAll")
                        if let processingPreferenceError {
                            Text(processingPreferenceError).foregroundStyle(ABDesign.red)
                                .multilineTextAlignment(.trailing)
                        }
                    }
                    .font(ABTypography.caption).foregroundStyle(ABDesign.secondaryText)
                    .frame(maxWidth: .infinity, alignment: .trailing)
                    .padding(.top, 16)
                }
            }.padding(.vertical, 28)
        }
    }

    private var canChangeProcessingPreference: Bool {
        Job.isTerminalStatus(meeting.status)
            && !viewModel.reprocessingMeetingIds.contains(meeting.id)
            && !viewModel.resummarizingMeetingIds.contains(meeting.id)
    }

    private func saveMicrophonePreference(_ excluded: Bool) {
        guard canChangeProcessingPreference else { return }
        do {
            try MeetingMetadataStore.setSkipsMicrophone(excluded, in: meeting.folderURL)
            skipMicrophone = excluded
            processingPreferenceError = nil
        } catch {
            processingPreferenceError = error.localizedDescription
        }
    }

    private func saveTitle() {
        guard !titleDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        viewModel.renameMeeting(meeting, title: titleDraft)
        renaming = false
    }
}

/// Native, selectable GitHub-flavored Markdown, including tables and task lists.
private struct MeetingMarkdownView: View {
    let text: String

    var body: some View {
        Markdown(text)
            .markdownTheme(.gitHub)
            .markdownTextStyle(\.text) {
                FontSize(ABTypography.bodyPointSize)
            }
            .textSelection(.enabled)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}
