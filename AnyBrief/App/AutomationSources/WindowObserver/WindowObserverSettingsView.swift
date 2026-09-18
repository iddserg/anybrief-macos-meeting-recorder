import SwiftUI

struct WindowObserverSettingsView: View {
    @Binding var settings: AppSettings
    @State private var selectedRuleID: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            WorkspaceSettingsSectionHeader(
                title: String(localized: "Window Observer"),
                isOn: $settings.automation.windowObserverSettings.enabled,
                showsStatus: false
            )

            VStack(alignment: .leading, spacing: 10) {
                LazyVGrid(columns: [GridItem(.flexible(), spacing: 24, alignment: .topLeading), GridItem(.flexible(), alignment: .topLeading)], alignment: .leading, spacing: 8) {
                    compactSettingField(
                        String(localized: "Action"),
                        help: String(localized: "What AnyBrief does when a window matches a rule. Notify only is useful for testing rules before enabling recording.")
                    ) {
                        Picker("", selection: $settings.automation.windowObserverSettings.actionMode) {
                            Text(String(localized: "Notify only")).tag(WindowObserverConfig.ActionMode.notify)
                            Text(String(localized: "Record and notify")).tag(WindowObserverConfig.ActionMode.recordAndNotify)
                        }
                        .font(ABTypography.field)
                        .pickerStyle(.menu).labelsHidden()
                    }

                    compactSettingField(
                        String(localized: "Windows"),
                        help: String(localized: "Active app checks only the focused application. All visible checks visible windows and may use more CPU.")
                    ) {
                        Picker("", selection: $settings.automation.windowObserverSettings.scope) {
                            Text(String(localized: "Active app")).tag(WindowObserverConfig.Scope.activeApplication)
                            Text(String(localized: "All visible")).tag(WindowObserverConfig.Scope.allVisibleWindows)
                        }
                        .font(ABTypography.field)
                        .pickerStyle(.menu).labelsHidden()
                    }

                    intervalField(
                        title: String(localized: "Stable for"),
                        help: String(localized: "The window must match continuously for this long before AnyBrief triggers an action."),
                        value: $settings.automation.windowObserverSettings.stableMatchSec,
                        range: 1...120
                    )
                    intervalField(
                        title: String(localized: "Check every"),
                        help: String(localized: "How often AnyBrief scans window titles. Higher values reduce CPU usage."),
                        value: $settings.automation.windowObserverSettings.pollIntervalSec,
                        range: 1...60
                    )

                }

                rulesSection
            }
            .disabled(!settings.automation.windowObserverSettings.enabled)
            .opacity(settings.automation.windowObserverSettings.enabled ? 1 : 0.45)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private func intervalField(title: String, help: String, value: Binding<Int>, range: ClosedRange<Int>) -> some View {
        HStack(spacing: 8) {
            HStack(spacing: 5) {
                Text(title).font(ABTypography.bodySemibold)
                HelpTooltipIcon(text: help)
            }
            Spacer(minLength: 0)
            WorkspaceIntegerStepper(
                title: title,
                valueText: String(format: String(localized: "%d sec"), value.wrappedValue),
                value: value,
                range: range
            )
        }
    }

    private func compactSettingField<Content: View>(
        _ label: String,
        help: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        HStack(spacing: 8) {
            HStack(spacing: 5) {
                Text(label).font(ABTypography.bodySemibold)
                HelpTooltipIcon(text: help)
            }
            Spacer(minLength: 0)
            content()
                .frame(maxWidth: .infinity, minHeight: WorkspaceDesign.controlHeight, alignment: .trailing)
        }
    }

    private var selectedRule: WindowObserverRule? {
        let rules = settings.automation.windowObserverSettings.rules
        return rules.first { $0.id == selectedRuleID } ?? rules.first
    }

    private var rulesSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 5) {
                Text(String(localized: "Match Rules"))
                    .font(ABTypography.bodySemibold)
                HelpTooltipIcon(text: String(localized: "Each enabled rule matches by application name and/or window title. Empty fields are ignored."))
            }
            HStack(spacing: 0) {
                VStack(spacing: 0) {
                    ScrollView {
                        VStack(spacing: WorkspaceDesign.listRowSpacing) {
                            ForEach(settings.automation.windowObserverSettings.rules) { rule in
                                Button {
                                    selectedRuleID = rule.id
                                } label: {
                                    HStack(spacing: 8) {
                                        Image(systemName: "macwindow")
                                            .frame(width: 16)
                                        Text(rule.name.isEmpty ? String(localized: "New rule") : rule.name)
                                            .lineLimit(2)
                                        Spacer(minLength: 0)
                                        if !rule.enabled {
                                            Image(systemName: "pause.circle")
                                                .accessibilityLabel(String(localized: "Disabled"))
                                        }
                                    }
                                    .font(ABTypography.bodyMedium)
                                    .foregroundStyle(selectedRule?.id == rule.id ? ABDesign.accent : ABDesign.primaryText)
                                    .padding(.horizontal, 8)
                                    .padding(.vertical, WorkspaceDesign.listRowVerticalInset)
                                    .frame(maxWidth: .infinity, minHeight: 32, alignment: .leading)
                                    .background(selectedRule?.id == rule.id ? ABDesign.selectedSidebarBackground : Color.clear)
                                    .clipShape(RoundedRectangle(cornerRadius: 6))
                                    .contentShape(Rectangle())
                                }
                                .buttonStyle(.plain)
                                .accessibilityIdentifier("windowObserver.rule.\(rule.id)")
                            }
                        }
                        .padding(8)
                    }
                    WorkspaceCollectionActions {
                        Button {
                            let rule = WindowObserverRule(name: String(localized: "New rule"), applicationPattern: "")
                            settings.automation.windowObserverSettings.rules.append(rule)
                            selectedRuleID = rule.id
                        } label: {
                            WorkspaceCollectionActionIcon(systemImage: "plus")
                        }
                        .help(Text(String(localized: "Add rule")))
                        .accessibilityLabel(String(localized: "Add rule"))
                        Button {
                            guard let rule = selectedRule else { return }
                            let rules = settings.automation.windowObserverSettings.rules
                            guard rules.count > 1 else { return }
                            let index = rules.firstIndex { $0.id == rule.id } ?? 0
                            settings.automation.windowObserverSettings.rules.removeAll { $0.id == rule.id }
                            let remaining = settings.automation.windowObserverSettings.rules
                            selectedRuleID = remaining[min(index, remaining.count - 1)].id
                        } label: {
                            WorkspaceCollectionActionIcon(systemImage: "minus")
                        }
                        .disabled(settings.automation.windowObserverSettings.rules.count <= 1)
                        .help(Text(String(localized: "Remove rule")))
                        .accessibilityLabel(String(localized: "Remove rule"))
                    }
                }
                .frame(width: 200)
                .background(WorkspaceDesign.secondarySurface)
                Divider()
                if let rule = selectedRule {
                    ruleEditor(WorkspaceCollectionBinding.item(rule, in: $settings.automation.windowObserverSettings.rules))
                        .id(rule.id)
                        .padding(12)
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                }
            }
            .frame(minHeight: 190, maxHeight: .infinity)
            .clipShape(RoundedRectangle(cornerRadius: 8))
            .overlay(RoundedRectangle(cornerRadius: 8).stroke(ABDesign.hairline))
        }
        .frame(maxHeight: .infinity, alignment: .topLeading)
    }

    private func ruleEditor(_ rule: Binding<WindowObserverRule>) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            compactRuleField(String(localized: "Name")) {
                HStack(spacing: 12) {
                    TextField("", text: rule.name).textFieldStyle(.roundedBorder)
                    Toggle(String(localized: "Enabled"), isOn: rule.enabled)
                        .toggleStyle(.switch).controlSize(.small)
                        .fixedSize()
                }
            }
            compactRuleField(String(localized: "Application contains")) {
                TextField("", text: rule.applicationPattern).textFieldStyle(.roundedBorder)
            }
            compactRuleField(String(localized: "Window title contains")) {
                TextField("", text: rule.titlePattern).textFieldStyle(.roundedBorder)
            }
        }
    }

    private func compactRuleField<Content: View>(
        _ label: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        HStack(spacing: 12) {
            Text(label)
                .font(ABTypography.bodySemibold)
                .foregroundStyle(ABDesign.primaryText)
                .frame(width: 150, alignment: .leading)
            content()
                .font(ABTypography.field)
                .controlSize(.regular)
                .frame(maxWidth: .infinity, minHeight: WorkspaceDesign.controlHeight, alignment: .leading)
        }
    }

}
