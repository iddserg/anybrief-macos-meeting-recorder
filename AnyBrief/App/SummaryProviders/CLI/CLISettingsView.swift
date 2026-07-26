
import SwiftUI

struct CLISettingsView: View {
    @Binding var configuration: SummaryProviderConfiguration

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top, spacing: 8) {
                Image(systemName: "exclamationmark.shield")
                    .font(ABTypography.caption)
                Text(String(localized: "CLI providers receive the full meeting transcript. AnyBrief wraps it as untrusted content and runs presets with restricted tools, but use only CLI tools and models you trust."))
                    .font(ABTypography.caption)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .foregroundStyle(.orange)
            .padding(8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.orange.opacity(0.10))
            .clipShape(RoundedRectangle(cornerRadius: 8))

            HStack(alignment: .top, spacing: 12) {
                SummaryProviderSettingsControls.labeledField(
                    String(localized: "Preset"),
                    help: String(localized: "Preset fills a trusted command template. Use Custom only when you know exactly what command should run.")
                ) {
                    Picker("", selection: $configuration.cliCommandPreset) {
                        Text("Codex").tag("codex")
                        Text("Claude").tag("claude")
                        Text("opencode").tag("opencode")
                        Text("Custom").tag("custom")
                    }
                    .pickerStyle(.menu)
                    .frame(width: 160)
                }
                if configuration.cliCommandPreset == "custom" {
                    SummaryProviderSettingsControls.labeledField(
                        String(localized: "Command"),
                        help: String(localized: "Custom commands run from the transcript folder and may return stdout or write summary.md."),
                        fillWidth: true
                    ) {
                        TextField("codex exec", text: $configuration.cliCommandLine)
                            .font(ABTypography.field)
                            .textFieldStyle(.roundedBorder)
                    }
                }
            }

            permissionsSection
        }
    }

    @ViewBuilder
    private var permissionsSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            if ["codex", "claude"].contains(configuration.cliCommandPreset) {
                apiPreflightControl
            }
            switch configuration.cliCommandPreset {
            case "codex":
                codexSandboxControl
            case "claude":
                claudeToolsControl
            case "opencode":
                opencodePermissionsControl
            default:
                EmptyView()
            }
        }
    }

    private var apiPreflightControl: some View {
        HStack(spacing: 6) {
            Toggle(
                String(localized: "Check API before launching CLI"),
                isOn: $configuration.cliAPIPreflightEnabled
            )
            .toggleStyle(.checkbox)
            .font(ABTypography.caption)

            HelpTooltipIcon(
                text: String(localized: "Checks that the Codex or Claude API is reachable before starting the CLI. If the domain is blocked or unavailable, AnyBrief immediately tries the next LLM connection.")
            )
        }
    }

    private var codexSandboxControl: some View {
        VStack(alignment: .leading, spacing: 6) {
            SummaryProviderSettingsControls.labeledField(
                String(localized: "Sandbox"),
                help: String(localized: "read-only never lets codex write files or reach the network. Loosen only if you trust this model and command.")
            ) {
                Picker("", selection: $configuration.cliCodexSandboxMode) {
                    Text("Read-only").tag("read-only")
                    Text("Workspace write").tag("workspace-write")
                    Text("Full access").tag("danger-full-access")
                }
                .pickerStyle(.menu)
                .frame(maxWidth: 220)
            }
            HStack(spacing: 6) {
                Toggle(
                    String(localized: "Ignore Codex user configuration"),
                    isOn: $configuration.cliCodexIgnoreUserConfig
                )
                .toggleStyle(.checkbox)
                .font(ABTypography.caption)

                HelpTooltipIcon(
                    text: String(localized: "Prevents Codex from loading user plugins, MCP servers, and settings for this request. Authentication is still used.")
                )
            }
            if configuration.cliCodexSandboxMode != "read-only" {
                permissionWarningBanner(String(localized: "This lets codex write files and/or reach the network while processing an untrusted transcript."))
            }
        }
    }

    private var claudeToolsControl: some View {
        VStack(alignment: .leading, spacing: 6) {
            SummaryProviderSettingsControls.labeledField(
                String(localized: "Allowed tools"),
                help: String(localized: "Comma-separated tool names passed to --tools. Empty denies every tool, which is the safe default.")
            ) {
                TextField(
                    String(localized: "None (deny all)"),
                    text: $configuration.cliClaudeAllowedTools
                )
                .font(ABTypography.field)
                .textFieldStyle(.roundedBorder)
                .frame(width: 320)
            }
            if !configuration.cliClaudeAllowedTools.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                permissionWarningBanner(String(localized: "Allowed tools can read, write, or run commands while processing an untrusted transcript."))
            }
        }
    }

    private var opencodePermissionsControl: some View {
        let permissions = Binding<OpencodePermissions>(
            get: { configuration.cliOpencodePermissions },
            set: { configuration.cliOpencodePermissions = $0 }
        )
        return VStack(alignment: .leading, spacing: 6) {
            SummaryProviderSettingsControls.labeledField(
                String(localized: "Permissions"),
                help: String(localized: "Every permission is denied by default. Allow only what this summary task actually needs.")
            ) {
                LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], alignment: .leading, spacing: 4) {
                    ForEach(Array(OpencodePermissions.allCases.enumerated()), id: \.offset) { _, entry in
                        let (keyPath, _, label) = entry
                        Toggle(label, isOn: permissions[dynamicMember: keyPath])
                            .toggleStyle(.checkbox)
                            .font(ABTypography.caption)
                    }
                }
            }
            if OpencodePermissions.allCases.contains(where: { permissions.wrappedValue[keyPath: $0.0] }) {
                permissionWarningBanner(String(localized: "Allowed permissions can read, write, run commands, or reach the network while processing an untrusted transcript."))
            }
        }
    }

    private func permissionWarningBanner(_ message: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "exclamationmark.shield")
                .font(ABTypography.caption)
            Text(message)
                .font(ABTypography.caption)
                .fixedSize(horizontal: false, vertical: true)
        }
        .foregroundStyle(.orange)
        .padding(8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.orange.opacity(0.10))
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }
}
