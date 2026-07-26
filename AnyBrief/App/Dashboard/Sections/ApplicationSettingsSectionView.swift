
import SwiftUI

extension DashboardView {
    var appSettingsGroup: some View {
        settingsGroup(title: String(localized: "App")) {
            VStack(alignment: .leading, spacing: 14) {
                labeledField(
                    String(localized: "Language"),
                    help: String(localized: "System follows the macOS language. Manual choices require saving settings and relaunching the app.")
                ) {
                    Picker("", selection: $viewModel.languageSelection) {
                        Text("🌐 System").tag("system")
                        Text("🇬🇧 English").tag("en")
                        Text("🇷🇺 Русский").tag("ru")
                    }
                    .font(ABTypography.field)
                    .pickerStyle(.menu)
                    .frame(width: 180)
                }

                VStack(alignment: .leading, spacing: 8) {
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
                    compactAppToggleRow(
                        String(localized: "Enable Live transcript (experimental)"),
                        help: String(localized: "Experimental feature. Captures system audio in rolling chunks and transcribes it live. Disabled by default; text may contain repeats while this is being refined."),
                        isOn: $viewModel.liveTranscriptEnabled
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
                                .frame(height: 34)
                                .padding(.horizontal, 12)
                        }
                        .buttonStyle(.bordered)

                        Button {
                            viewModel.exportSettingsConfig()
                        } label: {
                            Label(String(localized: "Export Config"), systemImage: "square.and.arrow.up")
                                .font(ABTypography.bodyMedium)
                                .frame(height: 34)
                                .padding(.horizontal, 12)
                        }
                        .buttonStyle(.bordered)
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
        Toggle(isOn: isOn) {
            HStack(spacing: 5) {
                Text(title)
                if let help {
                    HelpTooltipIcon(text: help)
                }
            }
        }
        .toggleStyle(.checkbox)
        .font(ABTypography.bodyMedium)
        .foregroundStyle(ABDesign.primaryText)
            .padding(.horizontal, 10)
            .frame(width: 430, alignment: .leading)
            .frame(minHeight: 34, alignment: .leading)
            .background(Color.black.opacity(0.025))
            .clipShape(RoundedRectangle(cornerRadius: 8))
    }

    var settingsSaveFooter: some View {
        VStack(alignment: .leading, spacing: 16) {
            if let saveMessage = viewModel.saveMessage {
                Text(saveMessage)
                    .font(ABTypography.bodyMedium)
                    .foregroundStyle(viewModel.saveMessageIsError ? .red : .green)
            }

            if viewModel.hasUnsavedSettings {
                HStack {
                    Spacer()
                    Button {
                        viewModel.saveSettings()
                    } label: {
                        Label(String(localized: "Save Settings"), systemImage: "checkmark.circle")
                            .font(ABTypography.bodySemibold)
                            .foregroundStyle(.white)
                            .padding(.horizontal, 28)
                            .frame(height: 48)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .disabled(!viewModel.canSaveSettings)
                    .background(
                        RoundedRectangle(cornerRadius: 9)
                            .fill(viewModel.canSaveSettings ? ABDesign.accent : Color.black.opacity(0.08))
                    )
                    .accessibilityIdentifier("settings.save")
                }
            }
        }
    }

    var automationSettingsGroup: some View {
        settingsGroup(title: String(localized: "Automation")) {
            VStack(alignment: .leading, spacing: 14) {
                ForEach(viewModel.automationSourceModules.indices, id: \.self) { index in
                    if index > 0 {
                        Divider()
                    }
                    viewModel.automationSourceModules[index].makeSettingsView(
                        context: viewModel.automationSourceSettingsViewContext()
                    )
                }

                if !viewModel.automationSourceModules.isEmpty {
                    Divider()
                }

                localHTTPAPISettings
            }
            .frame(maxWidth: 680, alignment: .leading)
        }
    }

    private var localHTTPAPISettings: some View {
        VStack(alignment: .leading, spacing: 14) {
            localHTTPAPIHeader

            VStack(alignment: .leading, spacing: 12) {
                labeledField(
                    String(localized: "Base URL"),
                    help: String(localized: "Local endpoint for external tools and automations. It listens on this Mac only unless network access is explicitly configured.")
                ) {
                    settingsReadOnlyField(viewModel.localAPIBaseURL) {
                        viewModel.copyToPasteboard(viewModel.localAPIBaseURL)
                    }
                }

                labeledField(
                    String(localized: "API Key"),
                    help: String(localized: "Required in X-API-Key for Local HTTP API requests. Regenerate it if a tool should lose access.")
                ) {
                    settingsReadOnlyField(viewModel.localApiKey.isEmpty ? "—" : viewModel.localApiKey) {
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
    }

    private var localHTTPAPIHeader: some View {
        HStack(spacing: 10) {
            Toggle("", isOn: $viewModel.localHTTPAPIEnabled)
                .toggleStyle(.switch)
                .labelsHidden()

            VStack(alignment: .leading, spacing: 4) {
                Text(String(localized: "Local HTTP API"))
                    .font(ABTypography.itemTitle)
                    .foregroundStyle(ABDesign.primaryText)
                Text(viewModel.localHTTPAPIEnabled ? String(localized: "Enabled") : String(localized: "Disabled"))
                    .font(ABTypography.caption)
                    .foregroundStyle(viewModel.localHTTPAPIEnabled ? ABDesign.green : ABDesign.secondaryText)
            }

            Spacer()
        }
        .padding(.horizontal, 10)
        .frame(maxWidth: .infinity, minHeight: 46, alignment: .leading)
        .background(Color.black.opacity(0.025))
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }

}
