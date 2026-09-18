
import SwiftUI

extension DashboardView {
    var transcriptionSettingsGroup: some View {
        settingsGroup(title: String(localized: "Transcription")) {
            HStack(spacing: 12) {
                ForEach(viewModel.transcriptionProviderRegistry.modules, id: \.id) { module in
                    transcriptionProviderOption(module)
                }
            }
            .accessibilityIdentifier("settings.transcription.providers")

            transcriptionBasicSettingsCard
            transcriptionModelStatusCard
            transcriptionTechnologyStatusCard
        }
        .onAppear { viewModel.refreshTranscriptionModelStatus() }
    }

    private func transcriptionProviderOption(_ module: any TranscriptionProviderModule) -> some View {
        let selected = module.id == viewModel.selectedTranscriptionProvider
        return Button {
            guard !selected else { return }
            viewModel.transcriptionProviderSelection = module.id.rawValue
            viewModel.transcriptionProviderDidChange()
        } label: {
            HStack(spacing: 10) {
                Image(systemName: module.systemImage)
                    .foregroundStyle(ABDesign.accent)
                Text(module.title)
                    .font(ABTypography.bodySemibold)
                    .foregroundStyle(ABDesign.primaryText)
                    .lineLimit(1)
                Spacer(minLength: 8)
                Image(systemName: selected ? "checkmark.circle.fill" : "circle")
                    .foregroundStyle(selected ? ABDesign.accent : ABDesign.secondaryText)
            }
            .padding(.horizontal, 14)
            .frame(maxWidth: .infinity, minHeight: 48)
            .background(selected ? ABDesign.selectedSidebarBackground : WorkspaceDesign.surface)
            .clipShape(RoundedRectangle(cornerRadius: 8))
            .overlay(RoundedRectangle(cornerRadius: 8)
                .stroke(selected ? ABDesign.accent : ABDesign.border, lineWidth: 1))
            .contentShape(RoundedRectangle(cornerRadius: 8))
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(selected ? .isSelected : [])
        .accessibilityIdentifier("settings.transcription.provider.\(module.id.rawValue)")
    }

    private var transcriptionBasicSettingsCard: some View {
        // Keep edits from the outgoing form attached to its provider when switching engines.
        let configuration = viewModel.draftTranscriptionConfiguration()
        return VStack(alignment: .leading, spacing: 20) {
            HStack(spacing: 10) {
                Button {
                    withAnimation(.easeInOut(duration: 0.18)) { transcriptionBasicSettingsExpanded.toggle() }
                } label: {
                    VStack(alignment: .leading, spacing: 3) {
                        Text(String(localized: "Basic settings"))
                            .font(ABTypography.bodySemibold)
                            .foregroundStyle(ABDesign.primaryText)
                        Text(selectedTranscriptionProviderModule.title)
                            .font(ABTypography.caption)
                            .foregroundStyle(ABDesign.secondaryText)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("settings.transcription.basic")
                disclosureButton(isExpanded: $transcriptionBasicSettingsExpanded)
            }

            if transcriptionBasicSettingsExpanded {
                Toggle(String(localized: "Separate speakers"), isOn: $viewModel.transcriptionDiarizationEnabled)
                    .onChange(of: viewModel.transcriptionDiarizationEnabled) { _, _ in viewModel.refreshTranscriptionModelStatus() }
                Toggle(String(localized: "Skip microphone diarization"), isOn: $viewModel.skipMicrophoneDiarization)
                    .disabled(!viewModel.transcriptionDiarizationEnabled)
                selectedTranscriptionProviderModule.makeSettingsView(
                    configuration: Binding(
                        get: { viewModel.transcriptionProviderEntries.first { $0.provider == configuration.provider } ?? configuration },
                        set: { viewModel.updateTranscriptionConfiguration($0) }),
                    diarizationEnabled: viewModel.transcriptionDiarizationEnabled
                )
                .id(configuration.provider)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(ABDesign.subtleBackground)
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }

    private var selectedTranscriptionProviderModule: any TranscriptionProviderModule {
        viewModel.transcriptionProviderRegistry.modules.first {
            $0.id == viewModel.selectedTranscriptionProvider
        } ?? viewModel.transcriptionProviderRegistry.modules[0]
    }

    var transcriptionModelStatusCard: some View {
        let status = viewModel.transcriptionModelStatus
        return VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top, spacing: 12) {
                Button {
                    withAnimation(.easeInOut(duration: 0.18)) {
                        transcriptionModelDetailsExpanded.toggle()
                    }
                } label: {
                    HStack(alignment: .top, spacing: 12) {
                        Image(systemName: status.isInstalled ? "checkmark.circle.fill" : "arrow.down.circle")
                            .font(ABTypography.iconMedium)
                            .foregroundStyle(status.isInstalled ? ABDesign.green : ABDesign.accent)
                            .frame(width: 24, height: 24)

                        VStack(alignment: .leading, spacing: 4) {
                            Text(String(localized: "Recognition model"))
                                .font(ABTypography.bodySemibold)
                                .foregroundStyle(ABDesign.primaryText)
                            Text(status.isInstalled ? String(localized: "Installed") : String(localized: "Not installed"))
                                .font(ABTypography.bodyMedium)
                                .foregroundStyle(status.isInstalled ? ABDesign.green : ABDesign.red)
                        }
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)

                Spacer()

                Button {
                    viewModel.downloadTranscriptionModels()
                } label: {
                    if viewModel.isDownloadingTranscriptionModels {
                        HStack(spacing: 8) {
                            ProgressView()
                                .controlSize(.small)
                            Text(String(localized: "Downloading…"))
                        }
                    } else {
                        Label(
                            status.isInstalled ? String(localized: "Download again") : String(localized: "Download models"),
                            systemImage: "arrow.down.circle"
                        )
                    }
                }
                .buttonStyle(WorkspaceButtonStyle())
                .disabled(viewModel.isDownloadingTranscriptionModels)

                disclosureButton(isExpanded: $transcriptionModelDetailsExpanded)
            }

            if transcriptionModelDetailsExpanded {
                Text(selectedTranscriptionProviderModule.title)
                    .font(ABTypography.caption).foregroundStyle(ABDesign.secondaryText)

                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(String(localized: "Path:"))
                        .font(ABTypography.captionSemibold)
                        .foregroundStyle(ABDesign.secondaryText)
                    Text(status.modelsDirectoryURL.path)
                        .font(ABTypography.mono)
                        .foregroundStyle(ABDesign.secondaryText)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .textSelection(.enabled)
                }

                    Text(
                        status.installedSizeBytes > 0
                            ? String(format: String(localized: "Cache size: %@"), status.installedSizeDescription)
                            : String(localized: "Cache size: not downloaded")
                    )
                    .font(ABTypography.caption)
                    .foregroundStyle(ABDesign.secondaryText)

                if !status.isInstalled {
                    Text(
                        String(
                            format: String(localized: "Missing files: %d"),
                            status.missingRelativePaths.count
                        )
                    )
                    .font(ABTypography.caption)
                    .foregroundStyle(ABDesign.secondaryText)
                }

                if let message = viewModel.transcriptionModelMessage {
                    Text(message)
                        .font(ABTypography.caption)
                        .foregroundStyle(viewModel.transcriptionModelMessageIsError ? ABDesign.red : ABDesign.green)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(ABDesign.subtleBackground)
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }

    var transcriptionTechnologyStatusCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                Button {
                    withAnimation(.easeInOut(duration: 0.18)) {
                        transcriptionTechnologyDetailsExpanded.toggle()
                    }
                } label: {
                    VStack(alignment: .leading, spacing: 3) {
                        Text(String(localized: "Provider technologies"))
                            .font(ABTypography.bodySemibold)
                            .foregroundStyle(ABDesign.primaryText)
                        Text(
                            viewModel.transcriptionTechnologyProviderTitle.isEmpty
                                ? String(localized: "Transcription provider")
                                : viewModel.transcriptionTechnologyProviderTitle
                        )
                        .font(ABTypography.caption)
                        .foregroundStyle(ABDesign.secondaryText)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)

                Spacer()

                Button {
                    viewModel.checkTranscriptionTechnologies()
                } label: {
                    if viewModel.isCheckingTranscriptionTechnologies {
                        HStack(spacing: 8) {
                            ProgressView()
                                .controlSize(.small)
                            Text(String(localized: "Checking…"))
                        }
                    } else {
                        Label(String(localized: "Check again"), systemImage: "arrow.clockwise")
                    }
                }
                .buttonStyle(WorkspaceButtonStyle())
                .disabled(viewModel.isCheckingTranscriptionTechnologies)

                disclosureButton(isExpanded: $transcriptionTechnologyDetailsExpanded)
            }

            if transcriptionTechnologyDetailsExpanded {
                if viewModel.transcriptionTechnologyChecks.isEmpty,
                   viewModel.isCheckingTranscriptionTechnologies {
                    Text(String(localized: "Checking the technologies required by this transcription provider."))
                        .font(ABTypography.caption)
                        .foregroundStyle(ABDesign.secondaryText)
                } else {
                    VStack(spacing: 0) {
                        ForEach(viewModel.transcriptionTechnologyChecks) { check in
                            HStack(alignment: .top, spacing: 10) {
                                Image(systemName: technologyIcon(for: check.status))
                                    .foregroundStyle(technologyColor(for: check.status))
                                    .frame(width: 18)

                                VStack(alignment: .leading, spacing: 3) {
                                    HStack(spacing: 6) {
                                        Text(check.title)
                                            .font(ABTypography.bodyMedium)
                                            .foregroundStyle(ABDesign.primaryText)
                                        if check.isRequired {
                                            Text(String(localized: "Required"))
                                                .font(ABTypography.caption)
                                                .foregroundStyle(ABDesign.secondaryText)
                                        }
                                    }
                                    Text(check.detail)
                                        .font(ABTypography.caption)
                                        .foregroundStyle(ABDesign.secondaryText)
                                        .fixedSize(horizontal: false, vertical: true)
                                        .textSelection(.enabled)
                                }
                                Spacer(minLength: 0)
                            }
                            .padding(.vertical, 8)

                            if check.id != viewModel.transcriptionTechnologyChecks.last?.id {
                                Divider()
                            }
                        }
                    }
                }

                if let message = viewModel.transcriptionTechnologyMessage {
                    Text(message)
                        .font(ABTypography.captionSemibold)
                        .foregroundStyle(
                            viewModel.transcriptionTechnologyMessageIsError
                                ? ABDesign.red
                                : ABDesign.green
                        )
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(ABDesign.subtleBackground)
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }

    private func disclosureButton(isExpanded: Binding<Bool>) -> some View {
        Button {
            withAnimation(.easeInOut(duration: 0.18)) {
                isExpanded.wrappedValue.toggle()
            }
        } label: {
            Image(systemName: "chevron.right")
                .font(ABTypography.captionSemibold)
                .foregroundStyle(ABDesign.secondaryText)
                .rotationEffect(.degrees(isExpanded.wrappedValue ? 90 : 0))
                .frame(width: 28, height: 28)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(
            isExpanded.wrappedValue
                ? String(localized: "Hide details")
                : String(localized: "Show details")
        )
    }

    private func technologyIcon(for status: TranscriptionTechnologyCheck.Status) -> String {
        switch status {
        case .ready:
            return "checkmark.circle.fill"
        case .warning:
            return "exclamationmark.triangle.fill"
        case .unavailable:
            return "xmark.circle.fill"
        }
    }

    private func technologyColor(for status: TranscriptionTechnologyCheck.Status) -> Color {
        switch status {
        case .ready:
            return ABDesign.green
        case .warning:
            return .orange
        case .unavailable:
            return ABDesign.red
        }
    }

}
