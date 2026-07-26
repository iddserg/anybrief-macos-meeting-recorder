import SwiftUI

extension DashboardView {
    enum ToolbarButtonRole {
        case plain
        case primary
        case destructive
    }

    var toolbar: some View {
        ZStack {
            HStack(alignment: .center, spacing: 10) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(selectedPane.title)
                        .font(ABTypography.pageTitle)
                        .foregroundStyle(ABDesign.primaryText)
                        .lineLimit(1)
                        .truncationMode(.tail)
                    if viewModel.needsPermissionSetup {
                        Text("Permissions are needed before recording.", comment: "Toolbar subtitle when required permissions are missing")
                            .font(ABTypography.pageSubtitle)
                            .foregroundStyle(ABDesign.secondaryText)
                            .lineLimit(1)
                            .truncationMode(.tail)
                    } else if let activity = viewModel.currentActivity {
                        Text(activity.summaryText)
                            .font(ABTypography.pageSubtitle)
                            .foregroundStyle(ABDesign.secondaryText)
                            .lineLimit(1)
                            .truncationMode(.tail)
                    } else {
                        Text("No active job.", comment: "Message when no recording job is active")
                            .font(ABTypography.pageSubtitle)
                            .foregroundStyle(ABDesign.secondaryText)
                            .lineLimit(1)
                            .truncationMode(.tail)
                    }
                }
                .frame(minWidth: 142, maxWidth: .infinity, minHeight: 46, maxHeight: 46, alignment: .leading)
                .layoutPriority(1)

                HStack(alignment: .center, spacing: 6) {
                    Spacer(minLength: 2)

                    if viewModel.needsPermissionSetup {
                        toolbarButton(
                            title: String(localized: "Permissions"),
                            systemImage: "lock.shield",
                            isEnabled: true
                        ) {
                            selectPane(.permissions)
                        }
                    } else {
                        statusPill(for: viewModel.effectiveAppState)
                    }

                    toolbarRecordButton(
                        title: String(localized: "Start Recording"),
                        label: String(localized: "Record"),
                        systemImage: "record.circle",
                        isEnabled: viewModel.canStartRecording,
                        action: viewModel.startRecording
                    )
                    .accessibilityIdentifier("toolbar.record.start")

                    toolbarIconButton(
                        title: viewModel.isStoppingRecording
                            ? String(localized: "Stopping Recording")
                            : String(localized: "Stop Recording"),
                        systemImage: viewModel.isStoppingRecording ? "hourglass" : "stop.circle",
                        role: .destructive,
                        isEnabled: viewModel.effectiveAppState == .recording && !viewModel.isStoppingRecording,
                        action: viewModel.stopRecording
                    )
                    .accessibilityIdentifier("toolbar.record.stop")

                    toolbarIconButton(
                        title: viewModel.isMicrophonePaused
                            ? String(localized: "Resume Microphone")
                            : String(localized: "Pause Microphone"),
                        systemImage: viewModel.isMicrophonePaused ? "mic.fill" : "mic.slash",
                        help: viewModel.isMicrophonePaused
                            ? String(localized: "Resume microphone capture.")
                            : String(localized: "Write silence to the microphone track while keeping system audio recording."),
                        isEnabled: viewModel.effectiveAppState == .recording,
                        action: viewModel.toggleMicrophonePause
                    )
                    .accessibilityIdentifier("toolbar.mic.toggle")

                    toolbarIconButton(
                        title: String(localized: "Force-stop Current Recording"),
                        systemImage: "xmark.circle",
                        help: String(localized: "Force-stop the active recording if the normal stop button is stuck."),
                        isEnabled: viewModel.currentActivity != nil,
                        action: viewModel.forceStopRecording
                    )
                    .accessibilityIdentifier("toolbar.record.forceStop")

                }
                .frame(height: 34, alignment: .center)
                .fixedSize(horizontal: true, vertical: false)
            }
            .padding(.horizontal, 16)
        }
        .frame(maxWidth: .infinity)
        .frame(height: 72, alignment: .center)
        .background(ABDesign.contentBackground)
        .zIndex(10)
    }

    func toolbarRecordButton(
        title: String,
        label: String,
        systemImage: String,
        isEnabled: Bool = true,
        action: @escaping () -> Void
    ) -> some View {
        Button {
            guard isEnabled else { return }
            action()
        } label: {
            Label(label, systemImage: systemImage)
                .font(ABTypography.bodySemibold)
                .labelStyle(.titleAndIcon)
                .lineLimit(1)
                .padding(.horizontal, 10)
                .frame(width: 104, height: 34)
                .foregroundStyle(isEnabled ? .white : ABDesign.disabledText)
                .background(
                    RoundedRectangle(cornerRadius: 8)
                        .fill(isEnabled ? ABDesign.accent : Color.black.opacity(0.035))
                )
        }
        .buttonStyle(.plain)
        .disabled(!isEnabled)
        .help(title)
        .fixedSize(horizontal: true, vertical: true)
    }

    func toolbarButton(
        title: String,
        systemImage: String,
        role: ToolbarButtonRole = .plain,
        isEnabled: Bool = true,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Label(title, systemImage: systemImage)
                .font(ABTypography.bodySemibold)
                .labelStyle(.titleAndIcon)
                .lineLimit(1)
                .minimumScaleFactor(0.82)
                .padding(.horizontal, 12)
                .frame(width: toolbarButtonWidth(for: role), height: 34)
                .foregroundStyle(toolbarForeground(for: role, isEnabled: isEnabled))
                .background(
                    RoundedRectangle(cornerRadius: 8)
                        .fill(toolbarBackground(for: role, isEnabled: isEnabled))
                )
        }
        .buttonStyle(.plain)
        .disabled(!isEnabled)
        .fixedSize(horizontal: true, vertical: true)
    }

    func toolbarButtonWidth(for role: ToolbarButtonRole) -> CGFloat? {
        switch role {
        case .plain:
            return nil
        case .primary:
            return 132
        case .destructive:
            return 140
        }
    }

    func toolbarIconButton(
        title: String,
        systemImage: String,
        role: ToolbarButtonRole = .plain,
        help: String? = nil,
        isEnabled: Bool = true,
        action: @escaping () -> Void
    ) -> some View {
        ToolbarIconButtonView(
            title: title,
            systemImage: systemImage,
            help: help ?? title,
            role: role,
            isEnabled: isEnabled,
            action: action
        )
    }

    func toolbarBackground(for role: ToolbarButtonRole, isEnabled: Bool) -> Color {
        guard isEnabled else {
            return Color.black.opacity(0.035)
        }
        switch role {
        case .plain:
            return ABDesign.controlBackground
        case .primary:
            return ABDesign.accent
        case .destructive:
            return ABDesign.red
        }
    }

    func toolbarForeground(for role: ToolbarButtonRole, isEnabled: Bool) -> Color {
        guard isEnabled else {
            return ABDesign.disabledText
        }
        switch role {
        case .plain:
            return ABDesign.primaryText
        case .primary, .destructive:
            return .white
        }
    }

    func statusPill(for state: AppState) -> some View {
        HStack(spacing: 5) {
            Circle()
                .fill(statusColor(for: state))
                .frame(width: 7, height: 7)
            Text(statusTitle(for: state))
                .font(ABTypography.captionSemibold)
                .foregroundStyle(ABDesign.primaryText)
                .lineLimit(1)
                .minimumScaleFactor(0.92)
                .layoutPriority(1)
            if state == .recording, let activity = viewModel.currentActivity {
                Text(Self.durationFormatter.string(from: activity.duration) ?? "")
                    .font(ABTypography.captionMedium)
                    .foregroundStyle(ABDesign.secondaryText)
                    .padding(.leading, 4)
                    .lineLimit(1)
                    .fixedSize(horizontal: true, vertical: false)
            }
        }
        .padding(.horizontal, 8)
        .frame(width: state == .recording ? 212 : 116, height: 34)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(ABDesign.controlBackground)
                .overlay(
                    RoundedRectangle(cornerRadius: 8)
                        .stroke(ABDesign.hairline, lineWidth: 1)
                )
        )
    }

    func statusPill(text: String, color: Color) -> some View {
        HStack(spacing: 6) {
            Circle()
                .fill(color)
                .frame(width: 7, height: 7)
            Text(text)
                .font(ABTypography.captionSemibold)
                .foregroundStyle(ABDesign.primaryText)
                .lineLimit(1)
        }
        .padding(.horizontal, 10)
        .frame(height: 34)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(ABDesign.controlBackground)
                .overlay(
                    RoundedRectangle(cornerRadius: 8)
                        .stroke(ABDesign.hairline, lineWidth: 1)
                )
        )
        .fixedSize(horizontal: true, vertical: true)
    }

    func statusTitle(for state: AppState) -> String {
        switch state {
        case .idle:
            return String(localized: "Idle")
        case .needsPermissions:
            return String(localized: "Needs setup")
        case .recording:
            return String(localized: "Recording")
        case .processing:
            return String(localized: "Processing")
        case .error:
            return String(localized: "Error")
        }
    }

    func statusColor(for state: AppState) -> Color {
        switch state {
        case .idle:
            return ABDesign.green
        case .needsPermissions:
            return ABDesign.yellow
        case .recording:
            return ABDesign.red
        case .processing:
            return ABDesign.yellow
        case .error:
            return ABDesign.red
        }
    }
}
