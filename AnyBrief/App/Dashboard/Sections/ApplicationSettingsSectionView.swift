
import SwiftUI

extension DashboardView {
    var appSettingsGroup: some View {
        settingsGroup(title: String(localized: "App")) {
            VStack(alignment: .leading, spacing: 24) {
                VStack(alignment: .leading, spacing: 0) {
                    settingsControlRow(String(localized: "Appearance")) {
                        Picker("", selection: $viewModel.appearanceSelection) {
                            Text("Light appearance").tag(AppAppearance.light)
                            Text("Dark appearance").tag(AppAppearance.dark)
                            Text("System appearance").tag(AppAppearance.system)
                        }
                        .pickerStyle(.segmented)
                        .labelsHidden()
                        .frame(width: 300)
                        .accessibilityLabel(String(localized: "Appearance"))
                        .accessibilityIdentifier("settings.appearance")
                    }

                    settingsControlRow(
                        String(localized: "Language"),
                        help: String(localized: "System follows the macOS language. Manual choices require saving settings and relaunching the app.")
                    ) {
                        Picker("", selection: $viewModel.languageSelection) {
                            Text("🌐 System").tag("system")
                            Text("🇬🇧 English").tag("en")
                            Text("🇷🇺 Русский").tag("ru")
                        }
                        .font(ABTypography.field)
                        .pickerStyle(.menu).labelsHidden()
                        .frame(width: 180)
                    }
                    compactAppToggleRow(
                        String(localized: "Launch at login"),
                        help: String(localized: "Starts AnyBrief automatically after you sign in to macOS."),
                        isOn: $viewModel.launchAtLogin
                    )
                    compactAppToggleRow(
                        String(localized: "Disable Dock icon"),
                        help: String(localized: "Keeps AnyBrief in the menu bar only. The app can still show the dashboard from the menu bar icon."),
                        isOn: $viewModel.hideDockIcon
                    )
                    compactAppToggleRow(
                        String(localized: "Enable notifications"),
                        help: String(localized: "Shows system notifications for recording events, automation matches, and important app state changes."),
                        isOn: $viewModel.showNotifications
                    )
                    compactAppToggleRow(
                        String(localized: "Disable Recorded with footer in summaries"),
                        help: String(localized: "Removes the AnyBrief attribution footer from generated summary files."),
                        isOn: $viewModel.disableSummaryFooter
                    )

                }

                VStack(alignment: .leading, spacing: 10) {
                    Text(String(localized: "Configuration"))
                        .font(ABTypography.bodySemibold)
                    HStack(spacing: 12) {
                        Button {
                            viewModel.importSettingsConfig()
                        } label: {
                            Label(String(localized: "Load Config"), systemImage: "square.and.arrow.down")
                                .font(ABTypography.bodyMedium)
                        }
                        .buttonStyle(WorkspaceButtonStyle())

                        Button {
                            viewModel.exportSettingsConfig()
                        } label: {
                            Label(String(localized: "Export Config"), systemImage: "square.and.arrow.up")
                                .font(ABTypography.bodyMedium)
                        }
                        .buttonStyle(WorkspaceButtonStyle())
                    }
                    Text(String(localized: "Export creates empty password/API key fields. Import stores filled secrets in Keychain."))
                        .font(ABTypography.caption)
                        .foregroundStyle(ABDesign.secondaryText)
                        .fixedSize(horizontal: false, vertical: true)
                    if let message = viewModel.configTransferMessage {
                        Text(message)
                            .font(ABTypography.caption)
                            .foregroundStyle(viewModel.configTransferMessageIsError ? .red : .green)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
            .frame(maxWidth: 680, alignment: .leading)
        }
    }

    private func compactAppToggleRow(_ title: String, help: String? = nil, isOn: Binding<Bool>) -> some View {
        settingsToggleRow(title: title, detail: help ?? "", isOn: isOn)
    }

    private func settingsControlRow<Content: View>(
        _ title: String,
        help: String? = nil,
        @ViewBuilder content: () -> Content
    ) -> some View {
        HStack(spacing: 20) {
            HStack(spacing: 5) {
                Text(title).font(ABTypography.bodyMedium)
                if let help { HelpTooltipIcon(text: help) }
            }
            Spacer(minLength: 20)
            content()
                .padding(.trailing, -8)
        }
        .foregroundStyle(ABDesign.primaryText)
        .padding(.vertical, 14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .overlay(alignment: .bottom) { Divider() }
    }

    var settingsSaveFooter: some View {
        HStack(spacing: 16) {
            if let saveMessage = viewModel.saveMessage {
                Text(saveMessage)
                    .font(ABTypography.caption)
                    .foregroundStyle(viewModel.saveMessageIsError ? ABDesign.red : ABDesign.green)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                Text(viewModel.hasUnsavedSettings ? String(localized: "Unsaved changes") : String(localized: "All changes saved"))
                    .font(ABTypography.caption)
                    .foregroundStyle(ABDesign.secondaryText)
            }
            Spacer(minLength: 0)
            Button(String(localized: "Save Settings")) { viewModel.saveSettings() }
                .buttonStyle(WorkspaceButtonStyle(prominent: true))
                .disabled(!viewModel.hasUnsavedSettings || !viewModel.canSaveSettings)
                .accessibilityIdentifier("settings.save")
        }
    }

    var microphoneSettingsGroup: some View {
        settingsGroup(title: String(localized: "Microphone")) {
            labeledField(
                String(localized: "Microphone"),
                help: String(localized: "Choose a specific microphone or follow the current macOS system input.")
            ) {
                Picker("", selection: $viewModel.microphoneDeviceUID) {
                    Text(systemMicrophonePickerTitle).tag("")
                    ForEach(viewModel.availableMicrophoneDevices) { device in
                        Text(device.name).tag(device.uid)
                    }
                    if !viewModel.microphoneDeviceUID.isEmpty,
                       !viewModel.availableMicrophoneDevices.contains(where: { $0.uid == viewModel.microphoneDeviceUID }) {
                        Text(String(localized: "Unavailable microphone")).tag(viewModel.microphoneDeviceUID)
                    }
                }
                .labelsHidden()
                .pickerStyle(.menu)
                .frame(maxWidth: 320, alignment: .leading)
            }

            settingsToggleRow(
                title: String(localized: "Microphone voice processing"),
                detail: String(localized: "If you record without headphones, turn this on to reduce speaker echo in the microphone track. Leave it off when using headphones."),
                help: String(localized: "Applies Apple's microphone voice-processing mode. It can reduce echo and background noise, but may slightly change voice tone."),
                isOn: $viewModel.microphoneVoiceProcessingEnabled
            )
        }
        .frame(maxWidth: 680, alignment: .leading)
    }

    private var systemMicrophonePickerTitle: String {
        guard let systemDevice = viewModel.availableMicrophoneDevices.first(where: \.isSystemDefault) else {
            return String(localized: "Follow system input")
        }
        return String(localized: "Follow system input") + " (\(systemDevice.name))"
    }

    @ViewBuilder
    var windowObserverSettingsGroup: some View {
        if let module = viewModel.automationSourceRegistry.modules.first(where: { $0.id == .windowObserver }) {
            module.makeSettingsView(context: viewModel.automationSourceSettingsViewContext())
                .frame(maxWidth: 680, maxHeight: .infinity, alignment: .topLeading)
        }
    }

    var localHTTPAPISettingsGroup: some View {
        VStack(alignment: .leading, spacing: 24) {
            localHTTPAPIHeader

            VStack(alignment: .leading, spacing: 12) {
                labeledField(
                    String(localized: "Base URL"),
                    help: String(localized: "Local endpoint for external tools and automations. It listens on this Mac only.")
                ) {
                    settingsReadOnlyField(viewModel.localAPIBaseURL) {
                        viewModel.copyToPasteboard(viewModel.localAPIBaseURL)
                    }
                }

                labeledField(
                    String(localized: "API Key"),
                    help: String(localized: "Required in X-API-Key for Local HTTP API requests. Regenerate it if a tool should lose access.")
                ) {
                    settingsReadOnlyField(viewModel.localApiKey.isEmpty ? "—" : "••••••••••••••••") {
                        viewModel.copyToPasteboard(viewModel.localApiKey)
                    }
                }

                HStack(spacing: 12) {
                    Button(String(localized: "API Docs")) {
                        NSWorkspace.shared.open(viewModel.apiDocsURL)
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.blue)
                    .font(ABTypography.bodyMedium)

                    Spacer()

                    settingsActionButton(String(localized: "Regenerate Key")) {
                        viewModel.regenerateLocalApiKey()
                    }

                    settingsActionButton(String(localized: "Copy")) {
                        let text = """
                        Base URL: \(viewModel.localAPIBaseURL)
                        X-API-Key: \(viewModel.localApiKey)
                        """
                        viewModel.copyToPasteboard(text)
                    }
                    .disabled(viewModel.localApiKey.isEmpty)
                }
            }
            .disabled(!viewModel.localHTTPAPIEnabled)
            .opacity(viewModel.localHTTPAPIEnabled ? 1 : 0.45)
        }
        .frame(maxWidth: 680, alignment: .leading)
    }

    private var localHTTPAPIHeader: some View {
        WorkspaceSettingsSectionHeader(
            title: String(localized: "Local HTTP API"),
            isOn: $viewModel.localHTTPAPIEnabled
        )
    }

}
