
import SwiftUI

extension DashboardView {
    var settingsCategoryTabs: some View {
        HStack(spacing: 0) {
            ForEach(SettingsCategory.allCases) { category in
                Button {
                    selectedSettingsCategory = category
                } label: {
                    Text(category.title)
                        .font(ABTypography.bodyMedium)
                        .lineLimit(1)
                        .frame(maxWidth: .infinity)
                        .frame(height: 42)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .foregroundStyle(selectedSettingsCategory == category ? Color.white : ABDesign.primaryText)
                .background(
                    Rectangle()
                        .fill(selectedSettingsCategory == category ? ABDesign.accent : Color.clear)
                )
                .accessibilityIdentifier("settings.category.\(category.rawValue)")

                if category.id != SettingsCategory.allCases.last?.id {
                    Rectangle()
                        .fill(ABDesign.hairline)
                        .frame(width: 1, height: 42)
                }
            }
        }
        .frame(height: 42)
        .clipShape(RoundedRectangle(cornerRadius: 9))
        .overlay(
            RoundedRectangle(cornerRadius: 9)
                .stroke(Color.black.opacity(0.14), lineWidth: 1)
        )
    }

    var summarySettingsGroup: some View {
        settingsGroup(title: String(localized: "LLM connections")) {
            Text(String(localized: "Configured connections are available for summarization and Live. Which connection each task uses is selected in the Prompts section."))
                .font(ABTypography.caption)
                .foregroundStyle(ABDesign.secondaryText)

            VStack(alignment: .leading, spacing: 10) {
                HStack(alignment: .top, spacing: 14) {
                    summaryProviderSidebar
                        .frame(width: 230)

                    if let configuration = selectedSummaryProviderConfigurationBinding {
                        summaryProviderDetails(configuration)
                            .frame(maxWidth: .infinity, alignment: .topLeading)
                    } else {
                        VStack(alignment: .leading, spacing: 12) {
                            Text(String(localized: "No LLM connections configured."))
                                .font(ABTypography.body)
                                .foregroundStyle(ABDesign.secondaryText)
                            summaryProviderAddMenu
                        }
                        .frame(maxWidth: .infinity, alignment: .topLeading)
                    }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    var selectedSummaryProviderConfigurationBinding: Binding<SummaryProviderConfiguration>? {
        let selectedIndex = viewModel.summaryProviderEntries.firstIndex {
            $0.id == viewModel.selectedSummaryProviderConfigurationID
        }
        guard let index = selectedIndex ?? viewModel.summaryProviderEntries.indices.first else {
            return nil
        }
        return $viewModel.summaryProviderEntries[index]
    }

    func summaryProviderAPIKeyBinding(for id: String) -> Binding<String> {
        Binding(
            get: { viewModel.summaryProviderAPIKeys[id] ?? "" },
            set: { viewModel.summaryProviderAPIKeys[id] = $0 }
        )
    }

    func summaryProviderModule(for provider: SummaryProvider) -> (any SummaryProviderModule)? {
        try? viewModel.summaryProviderRegistry.module(for: provider)
    }

    func localizedSummaryProviderTitle(_ module: any SummaryProviderModule) -> LocalizedStringKey {
        LocalizedStringKey(module.title)
    }

    var summaryProviderSidebar: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(String(localized: "Connections"))
                .font(ABTypography.bodySemibold)
                .foregroundStyle(ABDesign.primaryText)

            ScrollView(.vertical) {
                VStack(spacing: 4) {
                    ForEach($viewModel.summaryProviderEntries) { $configuration in
                        summaryProviderSidebarRow($configuration)
                    }
                }
                .padding(.trailing, 2)
            }
            .scrollIndicators(.automatic)
            .frame(maxHeight: 218)

            Spacer(minLength: 6)
            HStack(spacing: 8) {
                summaryProviderAddMenu
                summaryProviderRemoveButton
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(10)
        .frame(minHeight: 316, alignment: .topLeading)
        .background(Color.white.opacity(0.62))
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(Color.black.opacity(0.12), lineWidth: 1)
        )
    }

    func summaryProviderSidebarRow(_ configuration: Binding<SummaryProviderConfiguration>) -> some View {
        let value = configuration.wrappedValue
        let isSelected = viewModel.selectedSummaryProviderConfigurationID == value.id
        let module = summaryProviderModule(for: value.provider)

        return HStack(spacing: 7) {
            Button {
                viewModel.selectSummaryProviderConfiguration(value)
            } label: {
                HStack(spacing: 7) {
                    Image(systemName: module?.systemImage ?? "questionmark.square")
                        .frame(width: 16)
                    Text(summaryProviderSidebarLabel(value, module: module))
                        .font(ABTypography.captionMedium)
                        .lineLimit(1)
                    Spacer(minLength: 0)
                }
                .foregroundStyle(isSelected ? Color.white : ABDesign.primaryText)
                .padding(.horizontal, 8)
                .frame(maxWidth: .infinity, minHeight: 30, alignment: .leading)
                .background(isSelected ? ABDesign.accent : Color.clear)
                .clipShape(RoundedRectangle(cornerRadius: 6))
                .contentShape(RoundedRectangle(cornerRadius: 6))
            }
            .buttonStyle(.plain)
            .frame(maxWidth: .infinity)
            .accessibilityIdentifier("llm.connection.\(value.id)")

            Toggle("", isOn: configuration.enabled)
                .labelsHidden()
                .toggleStyle(.checkbox)

            VStack(spacing: 0) {
                Button {
                    viewModel.moveSummaryProviderConfiguration(value, direction: -1)
                } label: {
                    Image(systemName: "chevron.up")
                        .font(ABTypography.iconTiny)
                }
                .buttonStyle(.plain)

                Button {
                    viewModel.moveSummaryProviderConfiguration(value, direction: 1)
                } label: {
                    Image(systemName: "chevron.down")
                        .font(ABTypography.iconTiny)
                }
                .buttonStyle(.plain)
            }
            .frame(width: 14)
        }
        .frame(maxWidth: .infinity, minHeight: 34)
    }

    var summaryProviderAddMenu: some View {
        Menu {
            ForEach(viewModel.summaryProviderRegistry.modules, id: \.id) { module in
                Button {
                    viewModel.addSummaryProviderConfiguration(module.id)
                } label: {
                    Label {
                        Text(localizedSummaryProviderTitle(module))
                    } icon: {
                        Image(systemName: module.systemImage)
                    }
                }
                .disabled(!viewModel.canAddSummaryProviderConfiguration(module.id))
            }
        } label: {
            Image(systemName: "plus")
                .font(ABTypography.bodySemibold)
                .frame(width: 42, height: 32)
        }
        .menuStyle(.button)
    }

    var summaryProviderRemoveButton: some View {
        Button {
            guard let configuration = selectedSummaryProviderConfigurationBinding?.wrappedValue else {
                return
            }
            viewModel.removeSummaryProviderConfiguration(configuration)
        } label: {
            Image(systemName: "minus")
                .font(ABTypography.bodySemibold)
                .frame(width: 42, height: 20)
        }
        .controlSize(.small)
        .buttonStyle(.bordered)
        .disabled(viewModel.summaryProviderEntries.count <= 1)
    }

    @ViewBuilder
    func summaryProviderDetails(_ configuration: Binding<SummaryProviderConfiguration>) -> some View {
        let module = summaryProviderModule(for: configuration.wrappedValue.provider)
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                Image(systemName: module?.systemImage ?? "questionmark.square")
                    .foregroundStyle(ABDesign.accent)
                Text(module.map(localizedSummaryProviderTitle) ?? LocalizedStringKey(configuration.wrappedValue.provider.rawValue))
                    .font(ABTypography.sectionTitle)
                    .foregroundStyle(ABDesign.primaryText)
                Spacer()
            }

            SummaryProviderSettingsControls.wrappingFieldRow {
                SummaryProviderSettingsControls.labeledField(
                    String(localized: "Name"),
                    help: String(localized: "Optional label shown instead of the provider/model name in connection pickers.")
                ) {
                    TextField(
                        module.map(localizedSummaryProviderTitleString) ?? configuration.wrappedValue.provider.rawValue,
                        text: SummaryProviderSettingsControls.optionalStringBinding(configuration.name)
                    )
                    .font(ABTypography.field)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 220)
                }
                SummaryProviderSettingsControls.labeledField(
                    String(localized: "Timeout (sec)"),
                    help: String(localized: "How long to wait for this connection before treating the request as failed.")
                ) {
                    TextField(
                        "",
                        value: SummaryProviderSettingsControls.optionalIntBinding(
                            configuration.timeoutSec,
                            default: SummaryProviderConfiguration.defaultTimeoutSec
                        ),
                        format: .number
                    )
                    .font(ABTypography.field)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 80)
                }
                SummaryProviderSettingsControls.labeledField(
                    String(localized: "Retries"),
                    help: String(localized: "Number of attempts for this connection before falling back to the next one in the chain.")
                ) {
                    TextField(
                        "",
                        value: SummaryProviderSettingsControls.optionalIntBinding(
                            configuration.retryCount,
                            default: SummaryProviderConfiguration.defaultRetryCount
                        ),
                        format: .number
                    )
                    .font(ABTypography.field)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 80)
                }
            }

            if let module {
                module.makeSettingsView(context: SummaryProviderSettingsViewContext(
                    configuration: configuration,
                    apiKey: summaryProviderAPIKeyBinding(for: configuration.wrappedValue.id)
                ))
            } else {
                Text(String(localized: "Unsupported summary provider."))
                    .font(ABTypography.body)
                    .foregroundStyle(ABDesign.secondaryText)
            }

            summaryProviderDiagnosticRow(configuration.wrappedValue)
        }
    }

    func localizedSummaryProviderTitleString(_ module: any SummaryProviderModule) -> String {
        String(localized: String.LocalizationValue(module.title))
    }

    func summaryProviderSidebarLabel(_ configuration: SummaryProviderConfiguration, module: (any SummaryProviderModule)?) -> String {
        if let name = configuration.name?.trimmingCharacters(in: .whitespacesAndNewlines), !name.isEmpty {
            return name
        }
        return module.map(localizedSummaryProviderTitleString) ?? configuration.provider.rawValue
    }

    func summaryProviderDiagnosticRow(_ configuration: SummaryProviderConfiguration) -> some View {
        HStack(spacing: 10) {
            Button {
                viewModel.checkSummaryProviderConfiguration(configuration)
            } label: {
                Label(
                    viewModel.isCheckingSummaryProvider(configuration)
                        ? String(localized: "Checking…")
                        : String(localized: "Check"),
                    systemImage: "checkmark.circle"
                )
                .font(ABTypography.captionMedium)
                .frame(height: 26)
            }
            .buttonStyle(.bordered)
            .disabled(viewModel.isCheckingSummaryProvider(configuration))

            if let result = viewModel.summaryProviderDiagnosticResult(for: configuration) {
                summaryProviderDiagnosticBanner(result)
            }

            Spacer(minLength: 0)
        }
    }

    func summaryProviderDiagnosticBanner(_ result: SummaryProviderDiagnosticResult) -> some View {
        HStack(spacing: 8) {
            Image(systemName: summaryProviderDiagnosticIcon(result.status))
                .font(ABTypography.captionSemibold)
            Text(result.message)
                .font(ABTypography.caption)
                .lineLimit(1)
                .truncationMode(.tail)
        }
        .foregroundStyle(summaryProviderDiagnosticColor(result.status))
        .padding(.horizontal, 10)
        .frame(height: 30)
        .background(summaryProviderDiagnosticColor(result.status).opacity(0.10))
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }

    func summaryProviderDiagnosticIcon(_ status: SummaryProviderDiagnosticResult.Status) -> String {
        switch status {
        case .success:
            return "checkmark.circle.fill"
        case .warning:
            return "arrow.clockwise"
        case .failure:
            return "exclamationmark.triangle.fill"
        }
    }

    func summaryProviderDiagnosticColor(_ status: SummaryProviderDiagnosticResult.Status) -> Color {
        switch status {
        case .success:
            return ABDesign.green
        case .warning:
            return ABDesign.yellow
        case .failure:
            return ABDesign.red
        }
    }

}
