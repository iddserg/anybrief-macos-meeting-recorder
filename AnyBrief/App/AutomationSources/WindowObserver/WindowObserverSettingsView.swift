import SwiftUI

struct WindowObserverSettingsView: View {
    @Binding var settings: AppSettings

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                Toggle("", isOn: $settings.automation.windowObserverSettings.enabled)
                    .toggleStyle(.switch)
                    .labelsHidden()

                VStack(alignment: .leading, spacing: 4) {
                    Text(String(localized: "Window Observer"))
                        .font(ABTypography.itemTitle)
                        .foregroundStyle(ABDesign.primaryText)
                    Text(settings.automation.windowObserverSettings.enabled ? String(localized: "Enabled") : String(localized: "Disabled"))
                        .font(ABTypography.caption)
                        .foregroundStyle(settings.automation.windowObserverSettings.enabled ? ABDesign.green : ABDesign.secondaryText)
                }

                Spacer()
            }
            .padding(.horizontal, 10)
            .frame(maxWidth: .infinity, minHeight: 46, alignment: .leading)
            .background(Color.black.opacity(0.025))
            .clipShape(RoundedRectangle(cornerRadius: 8))

            VStack(alignment: .leading, spacing: 12) {
                HStack(alignment: .top, spacing: 10) {
                    labeledField(
                        String(localized: "Action"),
                        help: String(localized: "What AnyBrief does when a window matches a rule. Notify only is useful for testing rules before enabling recording.")
                    ) {
                        Picker("", selection: $settings.automation.windowObserverSettings.actionMode) {
                            Text(String(localized: "Notify only")).tag(WindowObserverConfig.ActionMode.notify)
                            Text(String(localized: "Record and notify")).tag(WindowObserverConfig.ActionMode.recordAndNotify)
                        }
                        .font(ABTypography.field)
                        .pickerStyle(.menu)
                        .frame(width: 155)
                    }
                    .frame(width: 165, alignment: .leading)

                    labeledField(
                        String(localized: "Windows"),
                        help: String(localized: "Active app checks only the focused application. All visible checks visible windows and may use more CPU.")
                    ) {
                        Picker("", selection: $settings.automation.windowObserverSettings.scope) {
                            Text(String(localized: "Active app")).tag(WindowObserverConfig.Scope.activeApplication)
                            Text(String(localized: "All visible")).tag(WindowObserverConfig.Scope.allVisibleWindows)
                        }
                        .font(ABTypography.field)
                        .pickerStyle(.menu)
                        .frame(width: 135)
                    }
                    .frame(width: 145, alignment: .leading)

                    labeledField(
                        String(localized: "Stable for"),
                        help: String(localized: "The window must match continuously for this long before AnyBrief triggers an action.")
                    ) {
                        Stepper(
                            String(
                                format: String(localized: "%d sec"),
                                settings.automation.windowObserverSettings.stableMatchSec
                            ),
                            value: $settings.automation.windowObserverSettings.stableMatchSec,
                            in: 1...120
                        )
                        .font(ABTypography.field)
                        .frame(width: 120)
                    }
                    .frame(width: 125, alignment: .leading)

                    labeledField(
                        String(localized: "Check every"),
                        help: String(localized: "How often AnyBrief scans window titles. Higher values reduce CPU usage.")
                    ) {
                        Stepper(
                            String(
                                format: String(localized: "%d sec"),
                                settings.automation.windowObserverSettings.pollIntervalSec
                            ),
                            value: $settings.automation.windowObserverSettings.pollIntervalSec,
                            in: 1...60
                        )
                        .font(ABTypography.field)
                        .frame(width: 120)
                    }
                    .frame(width: 145, alignment: .leading)

                    Spacer(minLength: 0)
                }

                rulesSection
            }
            .disabled(!settings.automation.windowObserverSettings.enabled)
            .opacity(settings.automation.windowObserverSettings.enabled ? 1 : 0.45)
        }
    }

    private var rulesSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                HStack(spacing: 5) {
                    Text(String(localized: "Match Rules"))
                        .font(ABTypography.bodySemibold)
                        .foregroundStyle(ABDesign.primaryText)
                    HelpTooltipIcon(
                        text: String(localized: "Each enabled rule matches by application name and/or window title. Empty fields are ignored.")
                    )
                }
                Spacer()
                Button {
                    settings.automation.windowObserverSettings.rules.append(
                        WindowObserverRule(
                            name: String(localized: "New rule"),
                            applicationPattern: "",
                            titlePattern: ""
                        )
                    )
                } label: {
                    Image(systemName: "plus")
                        .frame(width: 28, height: 28)
                }
                .buttonStyle(.bordered)
                .help(Text(String(localized: "Add rule")))
            }

            ForEach($settings.automation.windowObserverSettings.rules) { $rule in
                HStack(spacing: 8) {
                    Toggle("", isOn: $rule.enabled)
                        .toggleStyle(.checkbox)
                        .labelsHidden()
                        .frame(width: 22)

                    TextField(String(localized: "Name"), text: $rule.name)
                        .font(ABTypography.field)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 120)

                    TextField(String(localized: "Application contains"), text: $rule.applicationPattern)
                        .font(ABTypography.field)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 180)

                    TextField(String(localized: "Window title contains"), text: $rule.titlePattern)
                        .font(ABTypography.field)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 230)

                    Button {
                        settings.automation.windowObserverSettings.rules.removeAll { $0.id == rule.id }
                        if settings.automation.windowObserverSettings.rules.isEmpty {
                            settings.automation.windowObserverSettings.rules = WindowObserverRule.defaultRules
                        }
                    } label: {
                        Image(systemName: "trash")
                            .frame(width: 28, height: 28)
                    }
                    .buttonStyle(.borderless)
                    .foregroundStyle(ABDesign.red)
                    .help(Text(String(localized: "Remove rule")))
                }
            }
        }
    }

    private func labeledField<Content: View>(
        _ label: String,
        help: String? = nil,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 5) {
                Text(label)
                    .font(ABTypography.bodySemibold)
                    .foregroundStyle(ABDesign.primaryText)
                    .lineLimit(1)
                if let help {
                    HelpTooltipIcon(text: help)
                }
            }
            content()
        }
    }
}
