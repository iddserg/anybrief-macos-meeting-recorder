import SwiftUI

extension DashboardView {
    enum ToolbarButtonRole {
        case plain
        case primary
        case destructive
    }

    var toolbar: some View {
        HStack(spacing: 12) {
            Text(selectedPane.title).font(ABTypography.bodySemibold).lineLimit(1)
            Spacer(minLength: 12)
            Button { showingMeetingImport = true } label: {
                Label("Import", systemImage: "square.and.arrow.down")
            }.buttonStyle(WorkspaceButtonStyle())
                .help(Text("Import audio or video…"))
                .accessibilityIdentifier("toolbar.meeting.import")
            if viewModel.needsPermissionSetup {
                Button("Permissions") { selectPane(.permissions) }.buttonStyle(WorkspaceButtonStyle())
            }
            if let activity = viewModel.recordingActivity ?? viewModel.processingActivities.first {
                Button { selectPane(activity.isRecording ? .status : .processing) } label: {
                    HStack(spacing: 6) {
                        Circle().fill(activity.isRecording ? ABDesign.red : ABDesign.accent).frame(width: 6, height: 6)
                        Text(activity.isRecording ? Self.recordingTime(activity.duration) : activity.detailedStageLabel)
                            .monospacedDigit().lineLimit(1)
                    }.font(ABTypography.captionMedium)
                }.buttonStyle(.plain).help(Text("Current Activity"))
                if activity.isRecording || viewModel.isStoppingRecording {
                    Button(action: viewModel.stopRecording) {
                        Label(viewModel.isStoppingRecording ? String(localized: "Stopping Recording") : String(localized: "Stop Recording"), systemImage: "stop")
                    }
                    .buttonStyle(WorkspaceButtonStyle(prominent: true, destructive: true))
                    .disabled(viewModel.isStoppingRecording)
                    .accessibilityIdentifier("toolbar.record.stop")
                }
                if activity.isRecording {
                    Button(action: viewModel.forceStopRecording) {
                        Image(systemName: "xmark.octagon")
                            .frame(width: 16)
                    }
                    .buttonStyle(WorkspaceButtonStyle())
                    .help(Text("Force-stop Current Recording"))
                    .accessibilityLabel(Text("Force-stop Current Recording"))
                    .accessibilityIdentifier("toolbar.record.forceStop")
                }
            }
            if viewModel.effectiveAppState != .recording && !viewModel.isStoppingRecording {
                Button(action: viewModel.startRecording) {
                    Label(viewModel.isStartingRecording ? String(localized: "Starting") : String(localized: "New recording"), systemImage: "record.circle")
                }.buttonStyle(WorkspaceButtonStyle(prominent: true))
                    .disabled(!viewModel.canStartRecording).accessibilityIdentifier("toolbar.record.start")
            }
        }
        .padding(.horizontal, WorkspaceDesign.inset).frame(height: 58)
        .background(WorkspaceDesign.surface)
    }

    static func recordingTime(_ duration: TimeInterval) -> String {
        let seconds = max(0, Int(duration))
        return seconds >= 3600
            ? String(format: "%d:%02d:%02d", seconds / 3600, (seconds / 60) % 60, seconds % 60)
            : String(format: "%02d:%02d", seconds / 60, seconds % 60)
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
                        .fill(isEnabled ? ABDesign.accent : ABDesign.subtleBackground)
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
            return ABDesign.subtleBackground
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
