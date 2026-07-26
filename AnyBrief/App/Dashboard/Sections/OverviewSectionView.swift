
import SwiftUI

extension DashboardView {
    var currentActivitySection: some View {
        sectionCard(title: String(localized: "Current Activity")) {
            if let activity = viewModel.currentActivity {
                VStack(alignment: .leading, spacing: 10) {
                    VStack(alignment: .leading, spacing: 5) {
                        gridRow(label: String(localized: "Active job"), value: JobIDGenerator.compactDisplay(activity.jobId))
                            .help(activity.jobId)
                        gridRow(label: String(localized: "Current stage"), value: activity.detailedStageLabel)
                        if let fallbackText = activity.fallbackText {
                            gridRow(label: String(localized: "LLM fallback"), value: fallbackText)
                        }
                        if activity.showsSeparateStatus {
                            gridRow(label: String(localized: "Status"), value: DashboardStatusLabels.label(for: activity.status))
                        }
                        if activity.isRecording {
                            gridRow(label: String(localized: "Duration"), value: Self.durationFormatter.string(from: activity.duration) ?? "0s")
                        }
                    }

                    if activity.isRecording {
                        Divider()
                        AudioLevelMetersView(
                            store: viewModel.audioLevelStore,
                            microphonePaused: viewModel.isMicrophonePaused,
                            microphoneDevices: viewModel.availableMicrophoneDevices,
                            selectedMicrophoneDeviceUID: viewModel.microphoneDeviceUID,
                            onSelectMicrophone: viewModel.selectMicrophoneDevice
                        )
                    }
                }
            } else {
                emptyState(
                    systemImage: "waveform",
                    title: String(localized: "No active recording right now"),
                    message: String(localized: "Click “Start Recording” to record the call, system audio, and microphone."),
                    minHeight: 170
                )
            }
        }
    }

    func agentAccessRow(label: String, value: String, onCopy: @escaping () -> Void) -> some View {
        HStack(spacing: 10) {
            Text(label)
                .foregroundStyle(.secondary)
                .frame(width: 70, alignment: .leading)
            Text(value)
                .font(ABTypography.mono)
                .textSelection(.enabled)
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer()
            Button {
                onCopy()
            } label: {
                Image(systemName: "doc.on.doc")
            }
            .buttonStyle(.plain)
            .disabled(value == "—")
        }
    }

    func recentMeetingsSection(limit: Int?, showsMoreButton: Bool) -> some View {
        let meetings = limit.map { Array(viewModel.recentMeetings.prefix($0)) } ?? viewModel.recentMeetings

        return sectionCard {
            HStack {
                Text(String(localized: "Recent Meetings"))
                    .font(ABTypography.sectionTitle)
                Spacer()
                Button {
                    viewModel.openMeetingsFolder()
                } label: {
                    Label(String(localized: "Open Folder"), systemImage: "folder")
                        .font(ABTypography.bodyMedium)
                        .padding(.horizontal, 12)
                        .frame(height: 32)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .background(
                    RoundedRectangle(cornerRadius: 8)
                        .fill(ABDesign.controlBackground)
                        .overlay(
                            RoundedRectangle(cornerRadius: 8)
                                .stroke(ABDesign.hairline, lineWidth: 1)
                        )
                )
            }

            if viewModel.recentMeetings.isEmpty {
                emptyState(
                    systemImage: "calendar",
                    title: String(localized: "No meetings yet"),
                    message: String(localized: "After the first recording, recent meetings with quick actions will appear here."),
                    minHeight: 190
                )
            } else {
                LazyVStack(spacing: 0) {
                    RecentMeetingsHeader()
                    Divider()
                    ForEach(meetings) { meeting in
                        RecentMeetingRow(
                            meeting: meeting,
                            viewModel: viewModel
                        )
                        Divider()
                    }

                    if viewModel.summaryActionMessage != nil ||
                        (showsMoreButton && viewModel.recentMeetings.count > meetings.count) {
                        HStack(spacing: 12) {
                            if let summaryActionMessage = viewModel.summaryActionMessage {
                                statusBanner(
                                    message: summaryActionMessage,
                                    isError: viewModel.summaryActionMessageIsError
                                )
                            }
                            Spacer()
                            if showsMoreButton, viewModel.recentMeetings.count > meetings.count {
                                Button {
                                    selectedPane = .meetings
                                } label: {
                                    Label(String(localized: "More"), systemImage: "chevron.right")
                                }
                                .controlSize(.small)
                            }
                        }
                        .padding(.top, 8)
                    }
                }
            }
        }
    }

    func statusBanner(message: String, isError: Bool) -> some View {
        HStack(spacing: 8) {
            Image(systemName: isError ? "exclamationmark.triangle.fill" : "arrow.clockwise")
            Text(message)
                .font(ABTypography.caption)
                .lineLimit(1)
                .truncationMode(.tail)
        }
        .foregroundStyle(isError ? ABDesign.red : ABDesign.green)
    }

    func compactHelpText(_ text: String) -> some View {
        Text(text)
            .font(ABTypography.caption)
            .foregroundStyle(.secondary)
            .lineLimit(1)
            .truncationMode(.tail)
    }

    func emptyState(
        systemImage: String,
        title: String,
        message: String,
        minHeight: CGFloat
    ) -> some View {
        VStack(spacing: 16) {
            Spacer(minLength: 0)
            Image(systemName: systemImage)
                .font(ABTypography.iconHero)
                .foregroundStyle(ABDesign.secondaryText)
                .frame(width: 88, height: 88)
                .background(
                    Circle()
                        .fill(Color.white.opacity(0.72))
                        .overlay(
                            Circle()
                                .stroke(Color.black.opacity(0.12), lineWidth: 1)
                        )
                )

            VStack(spacing: 10) {
                Text(title)
                    .font(ABTypography.sectionTitle)
                    .foregroundStyle(ABDesign.primaryText)
                Text(message)
                    .font(ABTypography.body)
                    .foregroundStyle(ABDesign.secondaryText)
                    .multilineTextAlignment(.center)
                    .lineSpacing(4)
                    .frame(maxWidth: 520)
            }
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity)
        .frame(height: minHeight)
    }

    var autopilotSection: some View {
        sectionCard(fillsHeight: true) {
            VStack(alignment: .leading, spacing: 16) {
                HStack(spacing: 12) {
                    toolbarButton(
                        title: viewModel.calendarAutopilotEnabled
                            ? String(localized: "Disable Autopilot")
                            : String(localized: "Enable Autopilot"),
                        systemImage: viewModel.calendarAutopilotEnabled ? "pause.circle" : "play.circle",
                        role: viewModel.calendarAutopilotEnabled ? .destructive : .primary,
                        action: viewModel.toggleAutopilotEnabled
                    )

                    statusPill(
                        text: viewModel.calendarAutopilotEnabled
                            ? String(localized: "Autopilot is on")
                            : String(localized: "Autopilot is off"),
                        color: viewModel.calendarAutopilotEnabled ? ABDesign.green : ABDesign.secondaryText
                    )

                    Spacer()
                }

                if let error = viewModel.calendarScheduleError {
                    Label(error, systemImage: "exclamationmark.triangle")
                        .font(ABTypography.captionMedium)
                        .foregroundStyle(ABDesign.yellow)
                }

                AutopilotDayScheduleView(events: viewModel.todayAutopilotEvents)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
    }

    var settingsSection: some View {
        sectionCard(fillsHeight: true) {
            VStack(alignment: .leading, spacing: 22) {
                settingsCategoryTabs

                Group {
                    switch selectedSettingsCategory {
                    case .automation:
                        automationSettingsGroup
                    case .summary:
                        summarySettingsGroup
                    case .transcription:
                        transcriptionSettingsGroup
                    case .calendar:
                        calendarAutopilotSettingsGroup
                    case .app:
                        appSettingsGroup
                    }
                }
                .frame(
                    maxWidth: .infinity,
                    maxHeight: selectedSettingsCategory == .summary ? .infinity : nil,
                    alignment: .topLeading
                )

                settingsSaveFooter
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
    }

}
